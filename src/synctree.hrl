%% -*- mode: erlang; erlang-indent-level: 4; indent-tabs-mode: nil -*-
%% -------------------------------------------------------------------
%%
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
-ifndef(synctree_types_included).
-define(synctree_types_included, true).

-type action()  :: {put, key(), value()} | {delete, key()}.
-type actions() :: list(action()).
-type bucket()  :: non_neg_integer().
-type key()     :: {level(), bucket()}.
-type level()   :: byte().
-type value()   :: any().

-define(ST_LEVEL_BITS, 8).

-define(is_non_neg_integer(I),  (erlang:is_integer(I) andalso I >= 0)).
-define(is_pos_integer(I),      (erlang:is_integer(I) andalso I > 0)).
-define(is_st_bucket(B),        ?is_non_neg_integer(B)).
-define(is_st_level(L),
    (erlang:is_integer(L) andalso L >= 0 andalso L =< 255)).

-endif. % synctree_types_included
