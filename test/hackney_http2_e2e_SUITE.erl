%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%%
%%% @doc End-to-end tests for HTTP/2 against real servers.
%%%
%%% These tests validate HTTP/2 compliance against production servers:
%%% - nghttp2.org: Reference HTTP/2 implementation
%%% - www.google.com: Strict HTTP/2 enforcement
%%% - cloudflare.com: CDN with HTTP/2 optimizations
%%%
%%% Tests are skipped if network is unavailable.
%%%
%%% To run: rebar3 ct --suite=hackney_http2_e2e_SUITE

-module(hackney_http2_e2e_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    nghttp2_simple_get/1,
    nghttp2_concurrent_streams/1,
    google_strict_headers/1,
    cloudflare_http2/1,
    cloudflare_quic_pooled_h2_loop/1
]).

-define(TIMEOUT, 30000).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, e2e_tests}].

groups() ->
    [{e2e_tests, [sequence], [
        nghttp2_simple_get,
        nghttp2_concurrent_streams,
        google_strict_headers,
        cloudflare_http2,
        cloudflare_quic_pooled_h2_loop
    ]}].

init_per_suite(Config) ->
    application:ensure_all_started(hackney),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    %% Check network availability by doing a quick test
    case check_network() of
        ok -> Config;
        {error, Reason} -> {skip, {network_unavailable, Reason}}
    end.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Test Cases
%%====================================================================

%% @doc Simple GET request to nghttp2.org over HTTP/2.
nghttp2_simple_get(_Config) ->
    URL = <<"https://nghttp2.org/">>,
    Opts = [{protocols, [http2]}, {recv_timeout, ?TIMEOUT}],

    case hackney:get(URL, [], <<>>, Opts) of
        {ok, Status, Headers, Body} ->
            ct:log("Status: ~p", [Status]),
            ct:log("Headers: ~p", [Headers]),
            ct:log("Body length: ~p bytes", [byte_size(Body)]),

            %% Verify success
            true = Status >= 200 andalso Status < 400,

            %% Verify HTTP/2 was used (nghttp2 server header)
            case proplists:get_value(<<"server">>, Headers) of
                undefined -> ok;
                Server -> ct:log("Server: ~s", [Server])
            end,
            ok;
        {error, Reason} ->
            ct:fail({request_failed, Reason})
    end.

%% @doc Test concurrent streams to nghttp2.org.
nghttp2_concurrent_streams(_Config) ->
    URL = <<"https://nghttp2.org/">>,
    Opts = [{protocols, [http2]}, {recv_timeout, ?TIMEOUT}],

    %% Launch 5 concurrent requests
    Self = self(),
    Pids = [spawn_link(fun() ->
        Result = hackney:get(URL, [], <<>>, Opts),
        Self ! {done, self(), Result}
    end) || _ <- lists:seq(1, 5)],

    %% Collect results
    Results = [receive
        {done, Pid, Result} -> Result
    after ?TIMEOUT * 2 ->
        {error, timeout}
    end || Pid <- Pids],

    %% All should succeed
    lists:foreach(fun
        ({ok, Status, _Headers, _Body}) when Status >= 200, Status < 400 ->
            ok;
        ({ok, Status, _Headers, _}) ->
            ct:fail({unexpected_status, Status});
        ({error, Reason}) ->
            ct:fail({request_failed, Reason})
    end, Results),
    ok.

%% @doc Test against Google which has strict HTTP/2 header validation.
%% This test caught the Host header bug in PR #811.
google_strict_headers(_Config) ->
    URL = <<"https://www.google.com/">>,
    Opts = [{protocols, [http2]}, {recv_timeout, ?TIMEOUT}],

    case hackney:get(URL, [], <<>>, Opts) of
        {ok, Status, Headers, _Body} ->
            ct:log("Google Status: ~p", [Status]),
            ct:log("Google Headers: ~p", [Headers]),

            %% Google should return a valid response
            true = Status >= 200 andalso Status < 500,
            ok;
        {error, Reason} ->
            ct:fail({google_request_failed, Reason})
    end.

%% @doc Test against Cloudflare's HTTP/2 implementation.
cloudflare_http2(_Config) ->
    URL = <<"https://cloudflare.com/">>,
    Opts = [{protocols, [http2]}, {recv_timeout, ?TIMEOUT}],

    case hackney:get(URL, [], <<>>, Opts) of
        {ok, Status, Headers, _Body} ->
            ct:log("Cloudflare Status: ~p", [Status]),

            %% Check for Cloudflare server header
            case proplists:get_value(<<"server">>, Headers) of
                undefined -> ok;
                Server -> ct:log("Server: ~s", [Server])
            end,

            %% Should get a valid response
            true = Status >= 200 andalso Status < 500,
            ok;
        {error, Reason} ->
            ct:fail({cloudflare_request_failed, Reason})
    end.

%% @doc Regression test for pooled HTTP/2 reuse on cloudflare-quic.com.
%% Warm up a pooled H2 connection, then run two tight request loops in
%% parallel. Without the pooled-connection fix, one or both workers can
%% stall indefinitely on the shared H2 connection.
cloudflare_quic_pooled_h2_loop(_Config) ->
    case inet:gethostbyname("cloudflare-quic.com") of
        {error, Reason} ->
            {skip, {cloudflare_quic_unavailable, Reason}};
        {ok, _} ->
            URL = <<"https://cloudflare-quic.com/">>,
            Pool = cloudflare_quic_h2_pool_regression,
            Opts = [{pool, Pool}, {protocols, [http2]}, {recv_timeout, ?TIMEOUT}],

            ok = hackney_pool:start_pool(Pool, [{max_connections, 10}]),
            try
                %% Warm up the pool so the concurrent workers share the same H2 connection.
                {ok, 200, _, _} = hackney:request(get, URL, [], <<>>, Opts),
                {ok, SharedPid} = hackney_pool:checkout_h2("cloudflare-quic.com", 443, hackney_ssl, Opts),
                true = erlang:is_process_alive(SharedPid),
                timer:sleep(50),

                Results = run_request_loops(URL, Opts, 2, 3000, 10000),
                ct:log("Cloudflare QUIC pooled H2 results: ~p", [Results]),

                case Results of
                    [{done, Count1}, {done, Count2}] when Count1 > 0, Count2 > 0 ->
                        ok;
                    _ ->
                        ct:fail({pooled_h2_loop_failed, Results})
                end
            after
                catch hackney_pool:stop_pool(Pool),
                hackney_pool:unregister_h2_all(),
                hackney_conn_sup:stop_all()
            end
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private Check if network is available.
check_network() ->
    %% Try to resolve a well-known hostname
    case inet:gethostbyname("nghttp2.org") of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

run_request_loops(URL, Opts, WorkerCount, DurationMs, ReceiveTimeout) ->
    Parent = self(),
    Deadline = erlang:monotonic_time(millisecond) + DurationMs,
    Worker = fun Self(Count) ->
        case erlang:monotonic_time(millisecond) < Deadline of
            true ->
                case catch hackney:request(get, URL, [], <<>>, Opts) of
                    {ok, 200, _, _} ->
                        Self(Count + 1);
                    {'EXIT', Reason} ->
                        Parent ! {worker_result, self(), {exit, Reason, Count}};
                    Other ->
                        Parent ! {worker_result, self(), {error, Other, Count}}
                end;
            false ->
                Parent ! {worker_result, self(), {done, Count}}
        end
    end,
    Workers = maps:from_list([begin
        {Pid, MonRef} = spawn_monitor(fun() -> Worker(0) end),
        {Pid, MonRef}
    end || _ <- lists:seq(1, WorkerCount)]),
    collect_worker_results(Workers, ReceiveTimeout, []).

collect_worker_results(Workers, _ReceiveTimeout, Acc) when map_size(Workers) =:= 0 ->
    lists:reverse(Acc);
collect_worker_results(Workers, ReceiveTimeout, Acc) ->
    receive
        {worker_result, Pid, Result} ->
            case maps:take(Pid, Workers) of
                {MonRef, Rest} ->
                    erlang:demonitor(MonRef, [flush]),
                    collect_worker_results(Rest, ReceiveTimeout, [Result | Acc]);
                error ->
                    collect_worker_results(Workers, ReceiveTimeout, Acc)
            end;
        {'DOWN', _MonRef, process, _Pid, normal} ->
            collect_worker_results(Workers, ReceiveTimeout, Acc);
        {'DOWN', _MonRef, process, Pid, Reason} ->
            case maps:take(Pid, Workers) of
                {_, Rest} ->
                    collect_worker_results(Rest, ReceiveTimeout, [{crashed, Reason} | Acc]);
                error ->
                    collect_worker_results(Workers, ReceiveTimeout, Acc)
            end
    after ReceiveTimeout ->
        lists:reverse(Acc, lists:duplicate(map_size(Workers), timeout))
    end.
