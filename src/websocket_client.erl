%% 
%% Basic implementation of the WebSocket API:
%% http://dev.w3.org/html5/websockets/
%% However, it's not completely compliant with the WebSocket spec.
%% Specifically it doesn't handle the case where 'length' is included
%% in the TCP packet, SSL is not supported, and you don't pass a 'ws://type url to it.
%%
%% It also defines a behaviour to implement for client implementations.
%% @author Dave Bryson [http://weblog.miceda.org]
%%
-module(websocket_client).

-behaviour(gen_server).

%% API
-export([start/3,write/1,close/0,initial_request/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

%% Ready States
-define(CONNECTING,0).
-define(OPEN,1).
-define(CLOSED,2).

%% Behaviour definition
-export([behaviour_info/1]).

behaviour_info(callbacks) ->
    [{onmessage,1},{onopen,0},{onclose,0},{close,0},{send,1}];
behaviour_info(_) ->
    undefined.

-record(state, {socket,readystate=undefined,headers=[],callback}).

start(Host,Port,Mod) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [{Host,Port,Mod}], []).

init(Args) ->
    process_flag(trap_exit,true),
    [{Host,Port,Mod}] = Args,
    {ok, Sock} = gen_tcp:connect(Host,Port,[binary,{packet, 0},{active,true}]),
    
    %% Hardcoded path for now...
    Req = initial_request(Host,"/"),
    ok = gen_tcp:send(Sock,Req),
    inet:setopts(Sock, [{packet, http}]),
    
    {ok,#state{socket=Sock,callback=Mod}}.

%% Write to the server
write(Data) ->
    gen_server:cast(?MODULE,{send,Data}).

%% Close the socket
close() ->
    gen_server:cast(?MODULE,close).

handle_cast({send,Data}, State) ->
    gen_tcp:send(State#state.socket,[0] ++ Data ++ [255]),
    {noreply, State};

handle_cast(close,State) ->
    Mod = State#state.callback,
    Mod:onclose(),
    gen_tcp:close(State#state.socket),
    State1 = State#state{readystate=?CLOSED},
    {stop,normal,State1}.

%% Start handshake
handle_info({http,Socket,{http_response,{1,1},101,"Web Socket Protocol Handshake"}}, State) ->
    State1 = State#state{readystate=?CONNECTING,socket=Socket},
    {noreply, State1};

%% Extract the headers
handle_info({http,Socket,{http_header, _, Name, _, Value}},State) ->
    case State#state.readystate of
	?CONNECTING ->
	    H = [{Name,Value} | State#state.headers],
	    State1 = State#state{headers=H,socket=Socket},
	    {noreply,State1};
	undefined ->
	    %% Bad state should have received response first
	    {stop,error,State}
    end;

%% Once we have all the headers check for the 'Upgrade' flag 
handle_info({http,Socket,http_eoh},State) ->
    %% Validate headers, set state, change packet type back to raw
     case State#state.readystate of
	?CONNECTING ->
	     Headers = State#state.headers,
	     case proplists:get_value('Upgrade',Headers) of
		 "WebSocket" ->
		     inet:setopts(Socket, [{packet, raw}]),
		     State1 = State#state{socket=Socket},
		     Mod = State#state.callback,
		     Mod:onopen(),
		     {noreply,State1};
		 _Any  ->
		     {stop,error,State}
	     end;
	undefined ->
	    %% Bad state should have received response first
	    {stop,error,State}
    end;

%% Handshake complete, handle packets
handle_info({tcp, Socket, Data},State) ->
    % io:format("handle_info({tcp, ~p, ~p}, ~p)~n", [Socket, Data, State]),
    case State#state.readystate of
	?OPEN ->
        % io:format("Will call unframe with Data = ~p~n", [Data]),
	    D = unframe(binary_to_list(Data)),
	    Mod = State#state.callback,
	    Mod:onmessage(D),
	    {noreply, State};
    ?CONNECTING ->
        <<_:16/bytes,Rest/bytes>> = Data,
        case Rest of 
        <<>> -> {noreply, State#state{readystate=?OPEN}};
        _  -> handle_info({tcp, Socket, Rest}, State#state{readystate=?OPEN})
        end;
	_Any ->
	    {stop,error,State}
    end;

handle_info({tcp_closed, _Socket},State) ->
    Mod = State#state.callback,
    Mod:onclose(),
    {stop,normal,State};

handle_info({tcp_error, _Socket, _Reason},State) ->
    {stop,tcp_error,State};

handle_info({'EXIT', _Pid, _Reason},State) ->
    {noreply,State}.

handle_call(_Request,_From,State) ->
    {reply,ok,State}.

terminate(Reason, _State) ->
    error_logger:info_msg("Terminated ~p~n",[Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

initial_request(Host,Path) ->
    "GET "++ Path ++" HTTP/1.1\r\nUpgrade: WebSocket\r\nConnection: Upgrade\r\n" ++ 
	"Host: " ++ Host ++ "\r\n" ++
	"Origin: http://" ++ Host ++ "\r\n" ++
    "Sec-WebSocket-Key1: 4y n D9118J  7 9Z 2      4\r\n" ++
    "Sec-WebSocket-Key2: 1487^9  C9201V2\r\n\r\n" ++
    [16#cb, 16#15, 16#88, 16#c8, 
     16#91, 16#15, 16#e1, 16#92].

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------


unframe(_Param=[0|T]) -> 
    % io:format("unframe(~p)~n", [Param]),
    unframe1(T).
unframe1([255]) -> 
    % io:format("unframe1([255])~n"),
    [];
unframe1(_Param=[H|T]) -> 
    % io:format("unframe1(~p)~n", [Param]),
    [H|unframe1(T)].

    
