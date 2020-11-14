-module(esSyncSrv).

-behaviour(gen_server).

-include("erlSync.hrl").

-compile(inline).
-compile({inline_size, 128}).

%% API
-export([
   start_link/0,
   rescan/0,
   pause/0,
   unpause/0,
   setLog/1,
   getLog/0,
   curInfo/0,
   getOnsync/0,
   setOnsync/1,
   swSyncNode/1
]).

%% gen_server callbacks
-export([
   init/1,
   handle_call/3,
   handle_cast/2,
   handle_info/2,
   terminate/2
]).

-define(SERVER, ?MODULE).

-record(state, {
   status = running :: running | pause
   , srcFiles = #{} :: map()
   , onsyncFun = undefined
   , swSyncNode = false
   , sockMod = undefined
   , sock = undefined
}).

%% ************************************  API start ***************************
rescan() ->
   gen_server:cast(?SERVER, miRescan),
   esUtils:logSuccess("start rescaning source files..."),
   ok.

unpause() ->
   gen_server:cast(?SERVER, miUnpause),
   ok.

pause() ->
   gen_server:cast(?SERVER, miPause),
   esUtils:logSuccess("Pausing erlSync. Call erlSync:run() to restart"),
   ok.

curInfo() ->
   gen_server:call(?SERVER, miCurInfo).

setLog(T) when ?LOG_ON(T) ->
   esUtils:setEnv(log, T),
   esUtils:loadCfg(),
   esUtils:logSuccess("Console Notifications Enabled"),
   ok;
setLog(_) ->
   esUtils:setEnv(log, none),
   esUtils:loadCfg(),
   esUtils:logSuccess("Console Notifications Disabled"),
   ok.

getLog() ->
   ?esCfgSync:getv(log).

swSyncNode(IsSync) ->
   gen_server:cast(?SERVER, {miSyncNode, IsSync}),
   ok.

getOnsync() ->
   gen_server:call(?SERVER, miGetOnsync).

setOnsync(Fun) ->
   gen_server:call(?SERVER, {miSetOnsync, Fun}).

%% ************************************  API end   ***************************

start_link() ->
   gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
   erlang:process_flag(trap_exit, true),
   esUtils:loadCfg(),
   erlang:send_after(0, self(), doAfter),
   {ok, #state{}}.

handle_call(miGetOnsync, _, #state{onsyncFun = OnSync} = State) ->
   {reply, OnSync, State};
handle_call({miSetOnsync, Fun}, _, State) ->
   {reply, ok, State#state{onsyncFun = Fun}};
handle_call(miCurInfo, _, State) ->
   {reply, {erlang:get(), State}, State};
handle_call(_Request, _, State) ->
   {reply, ok, State}.

handle_cast(miPause, State) ->
   {noreply, State#state{status = pause}};
handle_cast(miUnpause, State) ->
   {noreply, State#state{status = running}};
handle_cast({miSyncNode, IsSync}, State) ->
   case IsSync of
      true ->
         {noreply, State#state{swSyncNode = true}};
      _ ->
         {noreply, State#state{swSyncNode = false}}
   end;
handle_cast(miRescan, State) ->
   SrcFiles = esUtils:collSrcFiles(false),
   {noreply, State#state{srcFiles = SrcFiles}};
handle_cast(_Msg, State) ->
   esUtils:logSuccess("recv unexpect cast msg..."),
   {noreply, State}.

handle_info({tcp, _Socket, Data}, #state{status = running, srcFiles = SrcFiles, onsyncFun = OnsyncFun, swSyncNode = SwSyncNode} = State) ->
   FileList = binary:split(Data, <<"\r\n">>, [global]),
   %% 收集改动了beam hrl src 文件 然后执行相应的逻辑
   {Beams, Hrls, Srcs} = esUtils:classifyChangeFile(FileList, [], [], []),
   esUtils:reloadChangedMod(Beams, SwSyncNode, OnsyncFun, []),
   case ?esCfgSync:getv(?compileCmd) of
      undefined ->
         esUtils:recompileChangeHrlFile(Hrls, SrcFiles, SwSyncNode),
         esUtils:recompileChangeSrcFile(Srcs, SwSyncNode),
         NewSrcFiles = esUtils:addNewFile(Srcs, SrcFiles),
         {noreply, State#state{srcFiles = NewSrcFiles}};
      CmdStr ->
         case Srcs =/= [] orelse Hrls =/= [] of
            true ->
               RetStr = os:cmd(CmdStr),
               RetList = string:split(RetStr, "\n", all),
               CmdMsg = io_lib:format("compile cmd:~p ~n", [CmdStr]),
               esUtils:logSuccess(CmdMsg),
               RetMsg = io_lib:format("the result: ~n ", []),
               esUtils:logSuccess(RetMsg),
               [
                  begin
                     OneMsg = io_lib:format("~p ~n", [OneRet]),
                     esUtils:logSuccess(OneMsg)
                  end || OneRet <- RetList, OneRet =/= []
               ],
               ok;
            _ ->
               ignore
         end,
         {noreply, State}
   end;
handle_info({inet_async, LSock, _Ref, Msg}, #state{sockMod = SockMod} = State) ->
   case Msg of
      {ok, Sock} ->
         %% make it look like gen_tcp:accept
         inet_db:register_socket(Sock, SockMod),
         inet:setopts(Sock, [{active, true}]),
         prim_inet:async_accept(LSock, -1),

         %% 建立了连接 先发送监听目录配置
         {AddSrcDirs, OnlySrcDirs, DelSrcDirs} = esUtils:mergeExtraDirs(false),
         AddStr = string:join([filename:nativename(OneDir) || OneDir <- AddSrcDirs], "|"),
         OnlyStr = string:join([filename:nativename(OneDir) || OneDir <- OnlySrcDirs], "|"),
         DelStr = string:join([filename:nativename(OneDir) || OneDir <- DelSrcDirs], "|"),
         AllStr = string:join([AddStr, OnlyStr, DelStr], "\r\n"),
         gen_tcp:send(Sock, AllStr),
         esUtils:logSuccess("erlSync connect fileSync success... ~n"),
         case ?esCfgSync:getv(?compileCmd) of
            undefined ->
               %% 然后收集一下监听目录下的src文件
               SrcFiles = esUtils:collSrcFiles(true),
               {noreply, State#state{status = running, sock = Sock, srcFiles = SrcFiles}};
            _ ->
               {noreply, State#state{status = running}}
         end;
      {error, closed} ->
         Msg = io_lib:format("error, closed listen sock error ~p~n", [closed]),
         esUtils:logErrors(Msg),
         {stop, normal, State};
      {error, Reason} ->
         Msg = io_lib:format("listen sock error ~p~n", [Reason]),
         esUtils:logErrors(Msg),
         {stop, Reason, State}
   end;
handle_info({tcp_closed, _Socket}, _State) ->
   Msg = io_lib:format("esSyncSrv receive tcp_closed ~n", []),
   esUtils:logErrors(Msg),
   {noreply, _State};
handle_info({tcp_error, _Socket, Reason}, _State) ->
   Msg = io_lib:format("esSyncSrv receive tcp_error Reason:~p ~n", [Reason]),
   esUtils:logErrors(Msg),
   {noreply, _State};
handle_info(doAfter, State) ->
   %% 启动tcp 异步监听 然后启动文件同步应用 启动定时器  等待建立连接 超时 就表示文件同步应用启动失败了 报错
   ListenPort = ?esCfgSync:getv(?listenPort),
   case gen_tcp:listen(ListenPort, ?TCP_DEFAULT_OPTIONS) of
      {ok, LSock} ->
         case prim_inet:async_accept(LSock, -1) of
            {ok, _Ref} ->
               {ok, SockMod} = inet_db:lookup_socket(LSock),
               spawn(fun() ->
                  case os:type() of
                     {win32, _Osname} ->
                        CmtStr = "start " ++ esUtils:fileSyncPath("fileSync.exe") ++ " ./ " ++ integer_to_list(ListenPort),
                        os:cmd(CmtStr);
                     _ ->
                        CmtStr = esUtils:fileSyncPath("fileSync") ++ " ./ " ++ integer_to_list(ListenPort),
                        os:cmd(CmtStr)
                  end end),
               erlang:send_after(4000, self(), waitConnOver),
               {noreply, State#state{sockMod = SockMod}};
            {error, Reason} ->
               Msg = io_lib:format("init prim_inet:async_accept error ~p~n", [Reason]),
               esUtils:logErrors(Msg),
               {stop, waitConnOver, State}
         end;
      {error, Reason} ->
         Msg = io_lib:format("failed to listen on ~p - ~p (~s) ~n", [ListenPort, Reason, inet:format_error(Reason)]),
         esUtils:logErrors(Msg),
         {stop, waitConnOver, State}
   end;
handle_info(waitConnOver, #state{sock = undefined} = State) ->
   Msg = io_lib:format("failed to start fileSync~n", []),
   esUtils:logErrors(Msg),
   {stop, waitConnOver, State};
handle_info(_Msg, State) ->
   {noreply, State}.

terminate(_Reason, _State) ->
   ok.
