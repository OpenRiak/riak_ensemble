%% -*- mode: erlang; erlang-indent-level: 4; indent-tabs-mode: nil -*-
%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 Basho Technologies, Inc.
%% Copyright (c) 2025 Workday, Inc.
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
%% Simple synctree tests that are stateless.
-module(synctree_pure).

%% Used by other test modules.
-export([
    build/1,
    expected_diff/2
]).

%% EUnit test entry.
-export([run_test_/0]).

%% Internal invoked by name.
-export([
    test_basic_ets/0,
    test_basic_leveled/0,
    test_basic_map/0,
    test_corrupt_ets/0,
    test_corrupt_leveled/0,
    test_corrupt_map/0,
    test_exchange_ets/0,
    test_exchange_leveled/0,
    test_exchange_map/0
]).

-include_lib("stdlib/include/assert.hrl").

-define(TEST(X), {timeout, 60, {test, ?MODULE, X}}).

run_test_() ->
    Timeout = 60,
    Tests = [
        ?TEST(test_basic_map),
        ?TEST(test_basic_ets),
        ?TEST(test_basic_leveled),
        ?TEST(test_corrupt_map),
        ?TEST(test_corrupt_ets),
        ?TEST(test_corrupt_leveled),
        ?TEST(test_exchange_map),
        ?TEST(test_exchange_ets),
        ?TEST(test_exchange_leveled)
    ],
    {timeout, Timeout, Tests}.

test_basic_map()        -> test_basic(synctree_map).
test_basic_ets()        -> test_basic(synctree_ets).
test_basic_leveled()    -> test_basic(synctree_leveled).

test_basic(Mod) ->
    T = build(100, Mod),
    Result = synctree:get(42, T),
    Expect = <<420:64/integer>>,
    ?assertEqual(Expect, Result),
    T2 = synctree:insert(42, <<42:64/integer>>, T),
    Result2 = synctree:get(42, T2),
    Expect2 = <<42:64/integer>>,
    ?assertEqual(Expect2, Result2),
    ok.

test_corrupt_map()      -> test_corrupt(synctree_map).
test_corrupt_ets()      -> test_corrupt(synctree_ets).
test_corrupt_leveled()  -> test_corrupt(synctree_leveled).

test_corrupt(Mod) ->
    T = build(10, Mod),
    Result = synctree:get(4, T),
    Expect = <<40:64/integer>>,
    ?assertEqual(Expect, Result),
    T2 = synctree:corrupt(4, T),
    Result2 = synctree:get(4, T2),
    ?assertMatch({corrupted, _, _}, Result2),
    T3 = synctree:rehash(T2),
    Result3 = synctree:get(4, T3),
    ?assertEqual(notfound, Result3),
    ok.

test_exchange_map()     -> test_exchange(synctree_map).
test_exchange_ets()     -> test_exchange(synctree_ets).
test_exchange_leveled() -> test_exchange(synctree_leveled).

test_exchange(Mod) ->
    Num = 50,
    Diff = 10,
    T1 = build(Num, Mod),
    T2 = build(Num-Diff, Mod),
    Result = synctree:local_compare(T1, T2),
    Expect = expected_diff(Num, Diff),
    ?assertEqual(Expect, lists:sort(Result)),
    ok.

build(N) ->
    build(N, synctree_ets).

build(N, Mod) ->
    {ok, T} = synctree:new(undefined, default, default, Mod),
    do_build(N, T).

do_build(0, T) ->
    T;
do_build(N, T) ->
    T2 = synctree:insert(N, <<(N*10):64/integer>>, T),
    do_build(N-1, T2).

expected_diff(Num, Diff) ->
    [{N, {<<(N*10):64/integer>>, '$none'}}
     || N <- lists:seq(Num - Diff + 1, Num)].
