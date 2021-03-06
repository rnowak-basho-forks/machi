%% -------------------------------------------------------------------
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

-module(corfurl_sequencer).

-behaviour(gen_server).

-export([start_link/1, stop/1, stop/2,
         get/2]).
-ifdef(TEST).
-export([start_link/2]).
-compile(export_all).
-endif.

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).
-ifdef(PULSE).
-compile({parse_transform, pulse_instrument}).
-endif.
-endif.

-define(SERVER, ?MODULE).
%% -define(LONG_TIME, 30*1000).
-define(LONG_TIME, 5*1000).

start_link(FLUs) ->
    start_link(FLUs, standard).

start_link(FLUs, SeqType) ->
    start_link(FLUs, SeqType, ?SERVER).

start_link(FLUs, SeqType, RegName) ->
    case gen_server:start_link({local, RegName}, ?MODULE, {FLUs, SeqType},[]) of
        {ok, Pid} ->
            {ok, Pid};
        {error, {already_started, Pid}} ->
            {ok, Pid};
        Else ->
            Else
    end.

stop(Pid) ->
    stop(Pid, stop).

stop(Pid, Method) ->
    Res = gen_server:call(Pid, stop, infinity),
    if Method == kill ->
            %% Emulate gen.erl's client-side behavior when the server process
            %% is killed.
            exit(killed);
       true ->
            Res
    end.

get(Pid, NumPages) ->
    {LPN, LC} = gen_server:call(Pid, {get, NumPages, lclock_get()}, ?LONG_TIME),
    lclock_update(LC),
    LPN.

%%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%%

init({FLUs, TypeOrSeed}) ->
    lclock_init(),
    MLP = get_max_logical_page(FLUs),
    if TypeOrSeed == standard ->
            {ok, MLP + 1};
       true ->
            {Seed, BadPercent, MaxDifference} = TypeOrSeed,
            random:seed(Seed),
            {ok, {MLP+1, BadPercent, MaxDifference}}
    end.

handle_call({get, NumPages, LC}, _From, MLP) when is_integer(MLP) ->
    NewLC = lclock_update(LC),
    {reply, {{ok, MLP}, NewLC}, MLP + NumPages};
handle_call({get, NumPages, LC}, _From, {MLP, BadPercent, MaxDifference}) ->
    NewLC = lclock_update(LC),
    Fudge = case random:uniform(100) of
                N when N < BadPercent ->
                    random:uniform(MaxDifference * 2) - MaxDifference;
                _ ->
                    0
            end,
    {reply, {{ok, erlang:max(1, MLP + Fudge)}, NewLC},
     {MLP + NumPages, BadPercent, MaxDifference}};
handle_call(stop, _From, MLP) ->
    {stop, normal, ok, MLP};
handle_call(_Request, _From, MLP) ->
    Reply = whaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
    {reply, Reply, MLP}.

handle_cast(_Msg, MLP) ->
    {noreply, MLP}.

handle_info(_Info, MLP) ->
    {noreply, MLP}.

terminate(_Reason, _MLP) ->
    ok.

code_change(_OldVsn, MLP, _Extra) ->
    {ok, MLP}.

%%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%%

get_max_logical_page(FLUs) ->
    lists:max([proplists:get_value(max_logical_page, Ps, 0) ||
                  FLU <- FLUs,
                  {ok, Ps} <- [corfurl_flu:status(FLU)]]).

-ifdef(PULSE).

lclock_init() ->
    lamport_clock:init().

lclock_get() ->
    lamport_clock:get().

lclock_update(LC) ->
    lamport_clock:update(LC).

-else.  % PULSE

lclock_init() ->
    ok.

lclock_get() ->
    ok.

lclock_update(_LC) ->
    ok.

-endif. % PLUSE
