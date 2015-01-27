%% -------------------------------------------------------------------
%%
%% riak_kv_wm_ping: simple Webmachine resource for availability test
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

%% @doc Webmachine resource describing ring constituent vnodes
%%      and hosts these reside on
%% ```
%% GET /ring/vnodes'''
%%
%%   Return a map of riak vnodes to hosts they are running on,
%%   as JSON object like this:
%%     `{"host1": {"port":8989, "vnodes":["dev1@host1", "dev2@host1", ...]}, ...}'

-module(riak_kv_wm_ring).

%% webmachine resource exports
-export([
         init/1,
         is_authorized/2,
         allowed_methods/2,
         content_types_provided/2,
         malformed_request/2,
         make_response/2
        ]).

-include_lib("webmachine/include/webmachine.hrl").

-type wm_reqdata() :: #wm_reqdata{}.
-type unixtime() :: non_neg_integer().

-define(DEFAULT_CACHE_EXPIRY_TIME, 15).

-record(ctx, {nvalue :: non_neg_integer(),
              cached_response  :: list() | undefined,
              last_cached =  0 :: unixtime(),
              expiry_time = ?DEFAULT_CACHE_EXPIRY_TIME :: unixtime()
             }).
-type ctx() :: #ctx{}.


%% ===================================================================
%% Webmachine API
%% ===================================================================

-spec init(list()) -> {ok, ctx()}.
init(Props) ->
    {ok, #ctx{expiry_time =
                  proplists:get_value(
                    ring_vnodes_cache_expiry_time, Props,
                    ?DEFAULT_CACHE_EXPIRY_TIME)}}.


-spec is_authorized(wm_reqdata(), ctx()) ->
    {term(), wm_reqdata(), ctx()}.
is_authorized(RD, Ctx) ->
    case riak_api_web_security:is_authorized(RD) of
        false ->
            {"Basic realm=\"Riak\"", RD, Ctx};
        {true, _SecContext} ->
            {true, RD, Ctx};
        insecure ->
            {{halt, 426}, wrq:append_to_response_body(
                            "Security is enabled and Riak only accepts HTTPS connections",
                            RD), Ctx}
    end.


malformed_request(RD, Ctx) ->
    case wrq:get_qs_value("nvalue", undefined, RD) of
        undefined ->
            {true,
             error_response("missing required parameter nvalue\n", RD),
             Ctx};
        Defined ->
            try list_to_integer(Defined) of
                Valid when Valid > 0 ->
                    {false, RD, Ctx#ctx{nvalue = Valid}};
                Invalid ->
                    {true,
                     error_response(
                       io_lib:format("invalid nvalue (~b)\n", [Invalid]),
                       RD),
                     Ctx}
            catch
                error:badarg ->
                    {true,
                     error_response(
                       io_lib:format("invalid nvalue (~p)\n", [Defined]),
                       RD),
                     Ctx}
            end
    end.


-spec allowed_methods(wm_reqdata(), ctx()) ->
    {[atom()], wm_reqdata(), ctx()}.
allowed_methods(RD, Ctx) ->
    {['GET'], RD, Ctx}.


-spec content_types_provided(wm_reqdata(), ctx()) ->
    {[{string(), atom()}], wm_reqdata(), ctx()}.
content_types_provided(RD, Ctx) ->
    {[{"application/json", make_response}], RD, Ctx}.


-spec make_response(wm_reqdata(), ctx()) ->
    {iolist(), wm_reqdata(), ctx()}.
make_response(RD, Ctx) ->
    case Ctx#ctx.cached_response /= undefined andalso
        Ctx#ctx.last_cached + Ctx#ctx.expiry_time < unixtime() of
        true ->
            {Ctx#ctx.cached_response, RD, Ctx};
        false ->
            {Response, ValidPer} = make_json(Ctx),
            {Response, RD, Ctx#ctx{cached_response = Response,
                                   last_cached = ValidPer}}
    end.


%% ===================================================================
%% Supporting functions
%% ===================================================================

error_response(Msg, RD) ->
    wrq:set_resp_header(
      "Content-Type", "text/plain",
      wrq:append_to_response_body(Msg, RD)).


make_json(Ctx) ->
-spec make_json(ctx()) -> {iolist(), unixtime()}.
    {Vnodes, ValidPer} = get_vnodes(Ctx),
    {mochijson2:encode(
       {struct, [{H, {struct, [{port, P}, {vnodes, VV}]}}
                 || {H, P, VV} <- Vnodes]}),
     ValidPer}.


-spec get_vnodes(ctx()) -> {list(), unixtime()}.
get_vnodes(_Ctx) ->
    %% TODO: Details = riak_core_apl:get_apl(
    Details = [{localhost, 8989, [dev8, dev9]}],
    {Details, unixtime()}.


-spec unixtime() -> unixtime().
unixtime() ->
    {NowMega, NowSec, _} = os:timestamp(),
    NowMega * 1000 * 1000 + NowSec.
