%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%%
%%% @doc Tests for HTTP/2 connection pooling in hackney_pool.

-module(hackney_pool_h2_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LOCAL_H2_HOST, "localhost").
-define(LOCAL_TIMEOUT, 5000).

%%====================================================================
%% Test Setup
%%====================================================================

setup() ->
    {ok, _} = application:ensure_all_started(hackney),
    ok.

cleanup(_) ->
    hackney_pool:unregister_h2_all(),
    hackney_conn_sup:stop_all(),
    ok.

%%====================================================================
%% HTTP/2 Pool Tests
%%====================================================================

h2_pool_test_() ->
    {
        "HTTP/2 pool tests",
        {
            setup,
            fun setup/0, fun cleanup/1,
            [
                {"checkout_h2 returns none when no connection", fun test_h2_checkout_none/0},
                {"register_h2 and checkout_h2", fun test_h2_register_checkout/0},
                {"unregister_h2 removes connection", fun test_h2_unregister/0},
                {"connection death cleans h2_connections", fun test_h2_connection_death/0}
            ]
        }
    }.

test_h2_checkout_none() ->
    %% Without any registered H2 connection, checkout should return none
    Result = hackney_pool:checkout_h2("test.example.com", 443, hackney_ssl, []),
    ?assertEqual(none, Result).

test_h2_register_checkout() ->
    %% Start a dummy process to act as a connection
    DummyConn = spawn(fun() -> receive stop -> ok end end),

    %% Register it as an H2 connection
    ok = hackney_pool:register_h2("h2test.example.com", 443, hackney_ssl, DummyConn, []),

    %% Wait a bit for the async cast to process
    timer:sleep(50),

    %% Checkout should now return the connection
    Result = hackney_pool:checkout_h2("h2test.example.com", 443, hackney_ssl, []),
    ?assertEqual({ok, DummyConn}, Result),

    %% Cleanup
    DummyConn ! stop.

test_h2_unregister() ->
    %% Start a dummy process
    DummyConn = spawn(fun() -> receive stop -> ok end end),

    %% Register it
    ok = hackney_pool:register_h2("h2unreg.example.com", 443, hackney_ssl, DummyConn, []),
    timer:sleep(50),

    %% Verify it's there
    ?assertEqual({ok, DummyConn}, hackney_pool:checkout_h2("h2unreg.example.com", 443, hackney_ssl, [])),

    %% Unregister
    ok = hackney_pool:unregister_h2(DummyConn, []),
    timer:sleep(50),

    %% Should be gone now
    ?assertEqual(none, hackney_pool:checkout_h2("h2unreg.example.com", 443, hackney_ssl, [])),

    %% Cleanup
    DummyConn ! stop.

test_h2_connection_death() ->
    %% Start a dummy process
    DummyConn = spawn(fun() -> receive stop -> ok end end),

    %% Register it
    ok = hackney_pool:register_h2("h2death.example.com", 443, hackney_ssl, DummyConn, []),
    timer:sleep(50),

    %% Verify it's there
    ?assertEqual({ok, DummyConn}, hackney_pool:checkout_h2("h2death.example.com", 443, hackney_ssl, [])),

    %% Kill the process
    DummyConn ! stop,
    timer:sleep(100),

    %% Pool should receive DOWN message and clean up - checkout returns none
    ?assertEqual(none, hackney_pool:checkout_h2("h2death.example.com", 443, hackney_ssl, [])).

%%====================================================================
%% Multiplexing Tests
%%====================================================================

h2_multiplexing_test_() ->
    {
        "HTTP/2 multiplexing tests",
        {
            setup,
            fun setup/0, fun cleanup/1,
            [
                {"multiple callers get same connection", fun test_h2_multiplexing/0},
                {"different hosts get different connections", fun test_h2_different_hosts/0}
            ]
        }
    }.

test_h2_multiplexing() ->
    %% Start a dummy connection process
    DummyConn = spawn(fun() -> receive stop -> ok end end),

    %% Register it
    ok = hackney_pool:register_h2("h2mux.example.com", 443, hackney_ssl, DummyConn, []),
    timer:sleep(50),

    %% Multiple checkouts should return the same connection (multiplexing)
    {ok, Conn1} = hackney_pool:checkout_h2("h2mux.example.com", 443, hackney_ssl, []),
    {ok, Conn2} = hackney_pool:checkout_h2("h2mux.example.com", 443, hackney_ssl, []),
    {ok, Conn3} = hackney_pool:checkout_h2("h2mux.example.com", 443, hackney_ssl, []),

    %% All should be the same connection (multiplexed)
    ?assertEqual(DummyConn, Conn1),
    ?assertEqual(DummyConn, Conn2),
    ?assertEqual(DummyConn, Conn3),
    ?assertEqual(Conn1, Conn2),
    ?assertEqual(Conn2, Conn3),

    %% Cleanup
    DummyConn ! stop.

test_h2_different_hosts() ->
    %% Start two dummy connections
    Conn1 = spawn(fun() -> receive stop -> ok end end),
    Conn2 = spawn(fun() -> receive stop -> ok end end),

    %% Register them for different hosts
    ok = hackney_pool:register_h2("host1.example.com", 443, hackney_ssl, Conn1, []),
    ok = hackney_pool:register_h2("host2.example.com", 443, hackney_ssl, Conn2, []),
    timer:sleep(50),

    %% Checkout for host1 should return Conn1
    ?assertEqual({ok, Conn1}, hackney_pool:checkout_h2("host1.example.com", 443, hackney_ssl, [])),

    %% Checkout for host2 should return Conn2
    ?assertEqual({ok, Conn2}, hackney_pool:checkout_h2("host2.example.com", 443, hackney_ssl, [])),

    %% They should be different
    ?assertNotEqual(Conn1, Conn2),

    %% Cleanup
    Conn1 ! stop,
    Conn2 ! stop.

%%====================================================================
%% Shared H2 Integration Tests
%%====================================================================

h2_shared_integration_test_() ->
    [
        {
            "shared H2 promotion releases pool accounting",
            {setup,
             fun() -> setup_local_h2(pool_h2_accounting) end,
             fun cleanup_local_h2/1,
             fun(Ctx) ->
                 [?_test(test_shared_h2_promotion_releases_accounting(Ctx))]
             end}
        },
        {
            "shared H2 survives creator exit",
            {setup,
             fun() -> setup_local_h2(pool_h2_owner_handoff) end,
             fun cleanup_local_h2/1,
             fun(Ctx) ->
                 [?_test(test_shared_h2_survives_creator_exit(Ctx))]
             end}
        },
        {
            "pooled H2 coalesced replies do not stall",
            {setup,
             fun() -> setup_local_h2(pool_h2_coalesce) end,
             fun cleanup_local_h2/1,
             fun(Ctx) ->
                 [?_test(test_pooled_h2_coalesced_replies_do_not_stall(Ctx))]
             end}
        },
        {
            "shared H2 GOAWAY replies all waiters",
            {setup,
             fun() -> setup_local_h2(pool_h2_goaway) end,
             fun cleanup_local_h2/1,
             fun(Ctx) ->
                 [?_test(test_shared_h2_goaway_replies_all_waiters(Ctx))]
             end}
        }
    ].

setup_local_h2(Pool) ->
    setup(),
    Port = local_h2_port(Pool),
    hackney_load_regulation:reset(?LOCAL_H2_HOST, Port),
    catch hackney_pool:stop_pool(Pool),
    {ok, ServerPid} = h2spec_server:start(Port),
    timer:sleep(100),
    ok = hackney_pool:start_pool(Pool, [{max_connections, 4}]),
    {Pool, ServerPid, Port}.

cleanup_local_h2({Pool, ServerPid, Port}) ->
    catch hackney_pool:stop_pool(Pool),
    catch h2spec_server:stop(ServerPid),
    hackney_load_regulation:reset(?LOCAL_H2_HOST, Port),
    cleanup(ok).

test_shared_h2_promotion_releases_accounting({Pool, _ServerPid, Port}) ->
    {_ConnPid, Opts} = warmup_shared_h2(Pool, Port),
    Stats = hackney_pool:get_stats(Pool),
    ?assertEqual(0, proplists:get_value(in_use_count, Stats)),
    ?assertEqual(0, hackney_load_regulation:current(?LOCAL_H2_HOST, Port)),
    ?assertEqual(0, proplists:get_value(free_count, Stats)),
    ?assertMatch({ok, _}, wait_for_shared_h2(Port, Opts, 20)).

test_shared_h2_survives_creator_exit({Pool, _ServerPid, Port}) ->
    Parent = self(),
    Opts = local_h2_opts(Pool),
    URL = local_h2_url(Port, <<"/">>),
    Requester = spawn(fun() ->
        Parent ! {warmup_result, catch hackney:request(get, URL, [], <<>>, Opts)}
    end),
    receive
        {warmup_result, {ok, 200, _, _}} ->
            ok
    after ?LOCAL_TIMEOUT ->
        ?assert(false)
    end,
    MonRef = erlang:monitor(process, Requester),
    receive
        {'DOWN', MonRef, process, Requester, _Reason} ->
            ok
    after ?LOCAL_TIMEOUT ->
        ?assert(false)
    end,
    {ok, ConnPid} = wait_for_shared_h2(Port, Opts, 20),
    timer:sleep(50),
    ?assert(erlang:is_process_alive(ConnPid)).

test_pooled_h2_coalesced_replies_do_not_stall({Pool, _ServerPid, Port}) ->
    {ConnPid, Opts} = warmup_shared_h2(Pool, Port),
    URL = local_h2_url(Port, <<"/coalesce">>),
    Results = run_concurrent_requests(URL, Opts, 2),
    ?assertEqual(2, length(Results)),
    ?assert(lists:all(fun(Result) -> matches_success(Result) end, Results)),
    ?assertEqual({ok, ConnPid}, hackney_pool:checkout_h2(?LOCAL_H2_HOST, Port,
                                                         hackney_ssl, Opts)).

test_shared_h2_goaway_replies_all_waiters({Pool, _ServerPid, Port}) ->
    {_ConnPid, Opts} = warmup_shared_h2(Pool, Port),
    URL = local_h2_url(Port, <<"/goaway_batch">>),
    Results = run_concurrent_requests(URL, Opts, 2),
    ?assertEqual(2, length(Results)),
    ?assert(lists:all(fun(Result) -> matches_error(Result) end, Results)).

warmup_shared_h2(Pool, Port) ->
    Opts = local_h2_opts(Pool),
    URL = local_h2_url(Port, <<"/">>),
    {ok, 200, _, _} = hackney:request(get, URL, [], <<>>, Opts),
    {ok, ConnPid} = wait_for_shared_h2(Port, Opts, 20),
    {ConnPid, Opts}.

local_h2_opts(Pool) ->
    [{pool, Pool},
     {protocols, [http2]},
     {recv_timeout, ?LOCAL_TIMEOUT},
     {ssl_options, [{verify, verify_none},
                    {server_name_indication, disable},
                    {verify_fun, {fun(_Cert, _Event, UserState) -> {valid, UserState} end, []}}]}].

local_h2_url(Port, Path) ->
    list_to_binary(io_lib:format("https://~s:~p~s",
                                 [?LOCAL_H2_HOST, Port, binary_to_list(Path)])).

wait_for_shared_h2(_Port, _Opts, 0) ->
    {error, timeout};
wait_for_shared_h2(Port, Opts, AttemptsLeft) ->
    case hackney_pool:checkout_h2(?LOCAL_H2_HOST, Port, hackney_ssl, Opts) of
        {ok, ConnPid} ->
            {ok, ConnPid};
        none ->
            timer:sleep(25),
            wait_for_shared_h2(Port, Opts, AttemptsLeft - 1)
    end.

local_h2_port(pool_h2_accounting) -> 18444;
local_h2_port(pool_h2_owner_handoff) -> 18445;
local_h2_port(pool_h2_coalesce) -> 18446;
local_h2_port(pool_h2_goaway) -> 18447.

run_concurrent_requests(URL, Opts, Count) ->
    Parent = self(),
    Workers = [begin
        {Pid, MonRef} = spawn_monitor(fun() ->
            Parent ! {worker_result, self(), catch hackney:request(get, URL, [], <<>>, Opts)}
        end),
        {Pid, MonRef}
    end || _ <- lists:seq(1, Count)],
    collect_worker_results(Workers, []).

collect_worker_results([], Acc) ->
    lists:reverse(Acc);
collect_worker_results(Workers, Acc) ->
    receive
        {worker_result, Pid, Result} ->
            case lists:keytake(Pid, 1, Workers) of
                {value, {_Pid, MonRef}, Rest} ->
                    erlang:demonitor(MonRef, [flush]),
                    collect_worker_results(Rest, [Result | Acc]);
                false ->
                    collect_worker_results(Workers, Acc)
            end;
        {'DOWN', _MonRef, process, Pid, Reason} ->
            case lists:keytake(Pid, 1, Workers) of
                {value, _Worker, Rest} ->
                    collect_worker_results(Rest, [{'EXIT', Reason} | Acc]);
                false ->
                    collect_worker_results(Workers, Acc)
            end
    after ?LOCAL_TIMEOUT * 2 ->
        lists:reverse(Acc)
    end.

matches_success({ok, 200, _, _}) ->
    true;
matches_success(_) ->
    false.

matches_error({'EXIT', _}) ->
    false;
matches_error({error, _}) ->
    true;
matches_error(Other) when is_tuple(Other), tuple_size(Other) =:= 4, element(1, Other) =:= ok ->
    false;
matches_error(_) ->
    false.
