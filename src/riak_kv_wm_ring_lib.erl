%% -------------------------------------------------------------------
%%
%% riak_kv_wm_ring_lib: Common functions for ring/coverage protobuff
%%                      callback and Webmachine resource
%%
%% Copyright (c) 2014 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Supporting functions shared between riak_kv_{wm,pb}_ring.

-module(riak_kv_wm_ring_lib).

-export([get_endpoints/2, get_endpoints_json/2]).

-type hplist() :: [{string(), non_neg_integer()}].

-define(RPC_TIMEOUT, 10000).

-spec get_endpoints_json(http|pb, {binary(), binary()}) -> iolist().
%% @doc Produce requested api endpoints in a JSON form.
get_endpoints_json(Proto, BKey) ->
    Endpoints = get_endpoints(Proto, BKey),
    mochijson2:encode(
       {struct, [{H, {struct, [{ports, P}]}}
                 || {H, P} <- Endpoints]}).


-spec get_endpoints(http|pb, {binary(), binary()}) -> hplist().
%% @doc For a given protocol, determine host:port endpoints of riak
%%      nodes containing requested bucket and key.
get_endpoints(Proto, {Bucket, Key}) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    UpNodes = riak_core_ring:all_members(Ring),
    Preflist = riak_core_apl:get_apl_ann({Bucket, Key}, UpNodes),
    Nodes =
        lists:usort(
          [N || {{_Index, N}, _Type} <- Preflist]),  %% filter on type?
    %% why bother with nodes? [{Host, [Port]}] is all our clients need, so:
    case Proto of
        http ->
            get_http_endpoints(Nodes);
        pb ->
            get_pb_endpoints(Nodes)
    end.


%% ===================================================================
%% Local functions
%% ===================================================================

-spec get_http_endpoints([node()]) -> hplist().
%% @private
get_http_endpoints(Nodes) ->
    {ResL, FailedNodes} =
        rpc:multicall(
          Nodes, riak_api_web, get_listeners, [], ?RPC_TIMEOUT),
    case FailedNodes of
        [] ->
            fine;
        FailedNodes ->
            lagger:warning(
              self(), "Failed to get http riak api listeners at node(s) ~9999p", [FailedNodes])
    end,
    %% there can be multiple api entry points (on multiple vnodes on same host),
    %% so group by host;
    lists:foldl(
      fun({H, P}, Acc) ->
              PP0 = proplists:get_value(H, Acc, []),
              lists:keystore(H, 1, Acc, {H, [P|PP0]})
      end, [],
      [HP || {_Proto, HP} <- lists:flatten(ResL)]).


-spec get_pb_endpoints([node()]) -> [{Host::string(), Port::non_neg_integer()}].
%% @private
get_pb_endpoints(Nodes) ->
    {ResL, FailedNodes} =
        rpc:multicall(
          Nodes, riak_api_pb_listener, get_listeners, [], ?RPC_TIMEOUT),
    case FailedNodes of
        [] ->
            fine;
        FailedNodes ->
            lagger:warning(
              self(), "Failed to get pb riak api listeners at node(s) ~9999p", [FailedNodes])
    end,
    lists:foldl(
      fun({H, P}, Acc) ->
              PP0 = proplists:get_value(H, Acc, []),
              lists:keystore(H, 1, Acc, {H, [P|PP0]})
      end, [],
      lists:flatten(ResL)).


%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).
%% TODO
-endif.
