%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2015 Basho Technologies, Inc.  All Rights Reserved.
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
%% 
%% @doc This process is responsible for managing filenames assigned to 
%% prefixes. It's started out of `machi_flu_psup'.
%%
%% Supported operations include finding the "current" filename assigned to
%% a prefix. Incrementing the sequence number and returning a new file name
%% and listing all data files assigned to a given prefix.
%%
%% All prefixes should have the form of `{prefix, P}'. Single filename
%% return values have the form of `{file, F}'.
%%
%% <h2>Finding the current file associated with a sequence</h2>
%% First it looks up the sequence number from the prefix name. If
%% no sequence file is found, it uses 0 as the sequence number and searches
%% for a matching file with the prefix and 0 as the sequence number.
%% If no file is found, the it generates a new filename by incorporating 
%% the given prefix, a randomly generated (v4) UUID and 0 as the
%% sequence number.
%%
%% If the sequence number is > 0, then the process scans the filesystem
%% looking for a filename which matches the prefix and given sequence number and
%% returns that.

-module(machi_flu_filename_mgr).
-behavior(gen_server).

-export([
    child_spec/2,
    start_link/2,
    find_or_make_filename_from_prefix/1,
    increment_prefix_sequence/1,
    list_files_by_prefix/1
    ]).

%% gen_server callbacks
-export([
    init/1,
    handle_cast/2,
    handle_call/3,
    handle_info/2,
    terminate/2,
    code_change/3
    ]).

-define(TIMEOUT, 10 * 1000).

%% public API

child_spec(FluName, DataDir) ->
    Name = make_filename_mgr_name(FluName),
    {Name, 
        {?MODULE, start_link, [FluName, DataDir]},
        permanent, 5000, worker, [?MODULE]}.

start_link(FluName, DataDir) when is_atom(FluName) andalso is_list(DataDir) ->
    gen_server:start_link({local, make_filename_mgr_name(FluName)}, ?MODULE, [DataDir], []).

-spec find_or_make_filename_from_prefix( Prefix :: {prefix, string()} ) ->
        {file, Filename :: string()} | {error, Reason :: term() } | timeout.
% @doc Find the latest available or make a filename from a prefix. A prefix
% should be in the form of a tagged tuple `{prefix, P}'. Returns a tagged
% tuple in the form of `{file, F}' or an `{error, Reason}'
find_or_make_filename_from_prefix({prefix, Prefix}) ->
    gen_server:call(?MODULE, {find_filename, Prefix}, ?TIMEOUT); 
find_or_make_filename_from_prefix(Other) ->
    lager:error("~p is not a valid prefix.", [Other]),
    error(badarg).

-spec increment_prefix_sequence( Prefix :: {prefix, string()} ) ->
        ok | {error, Reason :: term() } | timeout.
% @doc Increment the sequence counter for a given prefix. Prefix should
% be in the form of `{prefix, P}'. 
increment_prefix_sequence({prefix, Prefix}) ->
    gen_server:call(?MODULE, {increment_sequence, Prefix}, ?TIMEOUT); 
increment_prefix_sequence(Other) ->
    lager:error("~p is not a valid prefix.", [Other]),
    error(badarg).

-spec list_files_by_prefix( Prefix :: {prefix, string()} ) ->
    [ file:name() ] | timeout | {error, Reason :: term() }.
% @doc Given a prefix in the form of `{prefix, P}' return
% all the data files associated with that prefix. Returns
% a list.
list_files_by_prefix({prefix, Prefix}) ->
    gen_server:call(?MODULE, {list_files, Prefix}, ?TIMEOUT); 
list_files_by_prefix(Other) ->
    lager:error("~p is not a valid prefix.", [Other]),
    error(badarg).

%% gen_server API
init([DataDir]) ->
    {ok, DataDir}.

handle_cast(Req, State) ->
    lager:warning("Got unknown cast ~p", [Req]),
    {noreply, State}.

handle_call({find_filename, Prefix}, _From, DataDir) ->
    N = machi_util:read_max_filenum(DataDir, Prefix),
    File = case find_file(DataDir, Prefix, N) of
        [] ->
            {F, _} = machi_util:make_data_filename(
              DataDir,
              Prefix,
              generate_uuid_v4_str(),
              N),
             F;
        [H] -> H;
        [Fn | _ ] = L -> 
            lager:warning(
              "Searching for a matching file to prefix ~p and sequence number ~p gave multiples: ~p",
              [Prefix, N, L]),
            Fn
    end,
    {reply, {file, File}, DataDir};
handle_call({increment_sequence, Prefix}, _From, DataDir) ->
    ok = machi_util:increment_max_filenum(DataDir, Prefix),
    {reply, ok, DataDir};
handle_call({list_files, Prefix}, From, DataDir) ->
    spawn(fun() -> 
        L = list_files(DataDir, Prefix),
        gen_server:reply(From, L)
    end),
    {noreply, DataDir};

handle_call(Req, From, State) ->
    lager:warning("Got unknown call ~p from ~p", [Req, From]),
    {reply, hoge, State}.

handle_info(Info, State) ->
    lager:warning("Got unknown info ~p", [Info]),
    {noreply, State}.

terminate(Reason, _State) ->
    lager:info("Shutting down because ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% private

%% Quoted from https://github.com/afiskon/erlang-uuid-v4/blob/master/src/uuid.erl
%% MIT License
generate_uuid_v4_str() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", 
                        [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]).

find_file(DataDir, Prefix, N) ->
    {_Filename, Path} = machi_util:make_data_filename(DataDir, Prefix, "*", N),
    filelib:wildcard(Path).

list_files(DataDir, Prefix) ->
    {F, Path} = machi_util:make_data_filename(DataDir, Prefix, "*", "*"),
    filelib:wildcard(F, filename:dirname(Path)).

make_filename_mgr_name(FluName) when is_atom(FluName) ->
    list_to_atom(atom_to_list(FluName) ++ "_filename_mgr").