%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at

%%   http://www.apache.org/licenses/LICENSE-2.0


%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.    

%% @doc riak_redis_backend is a Riak storage backend using erldis.


-module(riak_kv_redis_backend).
-author('Eric Cestari <eric@ohmforce.com').
-author('Paul Peter Flis <pawel@flycode.pl').
-export([api_version/0,
         capabilities/1, capabilities/2,
         start/2,
         stop/1,
         get/3,
         put/5,
         delete/4,
         is_empty/1,
         fold_buckets/4,
         fold_keys/4,
         fold_objects/4
         ]).


-define(API_VERSION, 1).
-define(CAPABILITIES, []).              

-define(RSEND(V), redis_send(fun()-> V end)).
-define(PARTITION_NAME(P), list_to_binary(io_lib:format("riak_kv_redis_~s_~b", [node(), P]) )).
-define(REDIS, erldis_sync_client).

-type config() :: [].
-type state() :: proplists:proplist().

-record(state, {pid :: pid(),
                partition :: binary()}).


%% ===================================================================
%% Public API
%% ===================================================================

-spec api_version() -> {ok, integer()}.
api_version() ->
    {ok, ?API_VERSION}.

-spec capabilities(state()) -> {ok, [atom()]}.
capabilities(_) ->
    {ok, ?CAPABILITIES}.

-spec capabilities(riak_object:bucket(), state()) -> {ok, [atom()]}.
capabilities(_, _) ->
    {ok, ?CAPABILITIES}.

-spec start(integer(), config()) -> {ok, state()}.
start(Partition, Config)->
    {Host, Port} = riak_kv_util:get_backend_config(host, Config, redis_backend),
    
    {ok, Pid} = ?REDIS:connect(Host, Port),
    PName = ?PARTITION_NAME(Partition),
    {ok, #state{pid = Pid, partition = PName}}.

-spec stop(state()) -> ok | {error, Reason :: term()}.
stop(#state{pid = Pid}) ->
  ?REDIS:stop(Pid).

% get(state(), Key :: binary()) ->
%   {ok, Val :: binary()} | {error, Reason :: term()}
get(Bucket, Key, State=#state{partition = P, pid = Pid})->
    RKey = redis_key(P, Bucket, Key),
    case erldis:get(Pid, RKey) of
        nil -> {error, not_found, State};
        Val -> unpack(Val)
    end.

% put(state(), Key :: binary(), Val :: binary()) ->
%   ok | {error, Reason :: term()}  
put(Bucket, PrimKey, _IndexSpecs, Value, State=#state{partition = P, pid = Pid})->
    RKey = redis_key(P, Bucket, PrimKey),
    RVal = pack(Value),
    erldis:set_pipelining(Pid, true),
    erldis:sadd(Pid, <<"buckets:", P/binary>>, Bucket),
    erldis:set(Pid, RKey, RVal),
    erldis:sadd(Pid, <<P/binary, Bucket/binary>>, PrimKey),
    erldis:sadd(Pid, <<"world:", P/binary>>, term_to_binary({Bucket, PrimKey})),
    erldis:get_all_results(Pid),
    erldis:set_pipelining(Pid, false),
    {ok, State}.

% delete(state(), Key :: binary()) ->
%   ok | {error, Reason :: term()}
delete(Bucket, PrimKey, _IbdexSpecs, State=#state{partition = P, pid = Pid}) ->
    RKey = redis_key(P, Bucket, PrimKey),
    erldis:set_pipelining(Pid, true),
    erldis:srem(Pid, <<"buckets:", P/binary>>, Bucket),
    erldis:del(Pid, RKey),
    erldis:srem(Pid, <<P/binary, Bucket/binary>>, PrimKey),
    erldis:srem(Pid, <<"world:",P/binary>>, term_to_binary({Bucket, PrimKey})),
    erldis:get_all_results(Pid),
    erldis:set_pipelining(Pid, false),
    {ok, State}.

is_empty(#state{pid = Pid}) ->  
    erldis:dbsize(Pid) =:= 0.

fold_buckets(_,_,Opts,_) ->
    %% FIXME use lager
    io:format("~s:fold_buckets/4 not implement yet!~n", [?MODULE]),
    case lists:member(async_fold, Opts) of
        true  -> {ok, fun() -> [] end};
        false -> {ok, []}
    end.

fold_keys(_,_,_,_) ->
    %% FIXME use lager
    io:format("~s:fold_keys/4 not implement yet!~n", [?MODULE]),
    {ok, []}.

fold_objects(_,_,_,_) ->
    %% FIXME use lager
    io:format("~s:fold_objects/4 not implement yet!~n", [?MODULE]),
    {ok, []}.

% list(state()) -> [Key :: binary()]
%% list(#state {partition=P, pid=Pid }) ->
%%   lists:map(fun binary_to_term/1,
%%       erldis:smembers(Pid, <<"world:",P/binary>>)).

%% fold_buckets(FoldBucketsFun, Acc, Opts, #state{data_ref=DataRef}) ->

%% fold_buckets(#state {partition=P, pid=Pid }, '_')->
%%     FoldFun = fold_buckets_fun(FoldBucketsFun),
%%     erldis:smembers(Pid, <<"buckets:",P/binary>>);

%% list_bucket(#state {partition=P, pid=Pid }, {filter, Bucket, Fun})->
%%   lists:filter(Fun, erldis:smembers(Pid, <<P/binary,Bucket/binary>>));
%% list_bucket(#state {partition=P,  pid=Pid }, Bucket) ->
%%   erldis:smembers(Pid, <<P/binary,Bucket/binary>>).

redis_key(Partition, Bucket, Key)->
  <<Partition/binary, Bucket/binary, Key/binary>>.

pack(Value) ->
    term_to_binary(Value).

unpack(BinValue) ->
    case catch binary_to_term(BinValue) of
        {'EXIT', _}->
            throw({badterm, BinValue});
        TermVal -> TermVal
    end.
    
