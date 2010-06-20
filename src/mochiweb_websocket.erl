%% 
%% This is a wrapper around the mochiweb_socket_server.  It's based
%% on 'mochiweb_http' but handles the WebSocket protocol.
%% In this implementation there's no timeout set on reading from the socket so the
%% client connection does not timeout.
%% @author Dave Bryson [http://weblog.miceda.org]
%%
-module(mochiweb_websocket).

-export([start/0, start/1, stop/0, stop/1]).
-export([loop/2, default_hello/1]).

-define(DEFAULTS, [{name, ?MODULE},
                   {port, 8002}]).

-define(WEBSOCKET_PREFIX,"HTTP/1.1 101 Web Socket Protocol Handshake\r\nUpgrade: WebSocket\r\nConnection: Upgrade\r\n").

-define(HEX, [{"0", 0}, {"1", 1}, {"2", 2}, {"3", 3}, {"4", 4}, {"5", 5}, {"6", 6}, {"7", 7}, {"8", 8}, {"9", 9},
              {"a", 10}, {"b", 11}, {"c", 12}, {"d", 13}, {"e", 14}, {"f", 15}]).

set_default({Prop, Value}, PropList) ->
    case proplists:is_defined(Prop, PropList) of
        true ->
            PropList;
        false ->
            [{Prop, Value} | PropList]
    end.

set_defaults(Defaults, PropList) ->
    lists:foldl(fun set_default/2, PropList, Defaults).

parse_options(Options) ->
    {loop, MyLoop} = proplists:lookup(loop, Options),
    Loop = fun (S) ->
                   ?MODULE:loop(S, MyLoop)
           end,
    Options1 = [{loop, Loop} | proplists:delete(loop, Options)],
    set_defaults(?DEFAULTS, Options1).

stop() ->
    mochiweb_socket_server:stop(?MODULE).

stop(Name) ->
    mochiweb_socket_server:stop(Name).

start() ->
    start([{ip, "127.0.0.1"},
           {loop, {?MODULE, default_hello}}]).

start(Options) ->
    mochiweb_socket_server:start(parse_options(Options)).

%% Default loop if you start the server with 'start()'
default_hello(WebSocket) ->
    Data = WebSocket:get_data(),
    error_logger:info_msg("Rec from the client: ~p~n",[Data]),
    WebSocket:send("hello from the new WebSocket api").

loop(Socket, MyLoop) ->
    %% Set to http packet here to do handshake
    inet:setopts(Socket, [{packet, http}]),
    handshake(Socket,MyLoop).

handshake(Socket,MyLoop) ->
    case gen_tcp:recv(Socket, 0) of
	{ok, {http_request, _Method, Path, _Version}} ->
	    {abs_path,PathA} = Path,
	    check_header(Socket,PathA,[],MyLoop);
	{error, {http_error, "\r\n"}} ->
            handshake(Socket, MyLoop);
        {error, {http_error, "\n"}} ->
            handshake(Socket, MyLoop);
        Other ->
	    io:format("Got: ~p~n",[Other]),
            gen_tcp:close(Socket),
            exit(normal)
    end.

check_header(Socket,Path,Headers,MyLoop) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, http_eoh} ->
	    verify_handshake(Socket,Path,Headers),
	    %% Set packet back to raw for the rest of the connection
            inet:setopts(Socket, [{packet, raw}]),
            request(Socket,MyLoop);
        {ok, {http_header, _, Name, _, Value}} ->
            check_header(Socket, Path, [{Name, Value} | Headers],MyLoop);
        _Other ->
            gen_tcp:close(Socket),
            exit(normal)
    end.

verify_handshake(Socket,Path,Headers) ->
    error_logger:info_msg("Incoming Headers: ~p~n",[Headers]),
    
    case proplists:get_value('Upgrade',Headers) of
	"WebSocket" ->
	    send_handshake(Socket,Path,Headers);
	_Other ->
	    error_logger:error_msg("Incorrect WebSocket headers. Closing the connection~n"),
	    gen_tcp:close(Socket),
            exit(normal)
    end.

get_digit_space(String) ->
    char_filter([], [], String).
char_filter(Digits, Spaces, []) ->
    {list_to_integer(Digits), length(Spaces)};
char_filter(Digits, Spaces, [H|T]) ->
    try list_to_integer([H]),
        char_filter(Digits ++ [H], Spaces, T)
    catch error:_ ->
        case H of
            32  ->
                char_filter(Digits, Spaces ++ [H], T);
            _   ->
                char_filter(Digits, Spaces, T)
        end
    end.

make_challenge(Part_1, Part_2, Key_3) ->
    %Sample = to_32bit_int(lists:flatten(io_lib:format("~8.16.0b~8.16.0b", [906585445, 179922739]))) ++ "WjN}|M(6",
    %error_logger:info_msg("Sample: ~p~n", [{Sample, erlang:md5(Sample)}]),
    to_32bit_int(lists:flatten(io_lib:format("~8.16.0b~8.16.0b", [Part_1, Part_2]))) ++ binary_to_list(Key_3).
to_32bit_int(Parts) ->
    %error_logger:info_msg("to_32bit_int:Parts: ~p~n", [{Parts}]),
    to_32bit_int([], Parts).
to_32bit_int(Result, []) ->
    Result;
to_32bit_int(Result, [H1,H2|T]) ->
    {_, H1_} = lists:keyfind([H1], 1, ?HEX),
    {_, H2_} = lists:keyfind([H2], 1, ?HEX),
    %error_logger:info_msg("to_32bit_int:H1,H2: ~p~n", [{H1_, H2_}]),
    to_32bit_int(Result ++ [H1_*16+H2_], T).

send_handshake(Socket,Path,Headers) ->
    Origin = proplists:get_value("Origin",Headers),
    Location = proplists:get_value('Host',Headers),
    %draft-76: 5.2.2
    Key_1 = proplists:get_value("Sec-Websocket-Key1",Headers),
    Key_2 = proplists:get_value("Sec-Websocket-Key2",Headers),
    %draft-76: 5.2.4
    %draft-76: 5.2.5
    {Key_number_1, Spaces_1} = get_digit_space(Key_1),
    {Key_number_2, Spaces_2} = get_digit_space(Key_2),
    %draft-76: 5.2.6
    0 = Key_number_1 rem Spaces_1,
    0 = Key_number_2 rem Spaces_2,
    %draft-76: 5.2.7
    Part_1 = Key_number_1 div Spaces_1,
    Part_2 = Key_number_2 div Spaces_2,
    %draft-76: 5.2.8
    inet:setopts(Socket, [{packet, raw}]),
    {ok, Key_3} = gen_tcp:recv(Socket, 0),
    Challenge = make_challenge(Part_1, Part_2, Key_3),
    %draft-76: 5.2.9
    Response = erlang:md5(Challenge),
    %draft-76: 5.2.10
    Resp = ?WEBSOCKET_PREFIX ++
    %draft-76: 5.2.11
    "Sec-WebSocket-Origin: " ++ Origin ++ "\r\n" ++
    "Sec-WebSocket-Location: ws://" ++ Location ++ Path ++
    %draft-76: 5.2.12
    "\r\n\r\n" ++
    %draft-76: 5.2.13
    Response,
    %error_logger:info_msg("Sec-Websocket-Keys: ~p~n", [
            %[{"key_1", Key_1}, {"key_2", Key_2}, {"key_3", Key_3},
             %{"key-number_1", Key_number_1}, {"key-number_2", Key_number_2},
             %{"spaces_1", Spaces_1}, {"spaces_2", Spaces_2},
             %{"part_1", Part_1}, {"part_2", Part_2},
             %{"challenge", Challenge}, {"response", Response, binary_to_list(Response)}]]),
    gen_tcp:send(Socket, Resp).

request(Socket, MyLoop) ->
    WebSocketRequest = websocket_request:new(Socket),
    MyLoop(WebSocketRequest),
    request(Socket,MyLoop).
