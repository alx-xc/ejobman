%%%
%%% ejobman_stat: jobs statistic server
%%%
%%% Copyright (c) 2011 Megaplan Ltd. (Russia)
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"),
%%% to deal in the Software without restriction, including without limitation
%%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%%% and/or sell copies of the Software, and to permit persons to whom
%%% the Software is furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included
%%% in all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
%%% MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
%%% IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
%%% CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
%%% TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
%%% SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
%%%
%%% @author arkdro <arkdro@gmail.com>
%%% @since 2011-12-20 12:45
%%% @license MIT
%%% @doc Receives messages with jobs workflow data, keeps a limited number
%%% of messages in a storage, writes received data to a file storage.
%%% 

-module(ejobman_stat).
-behaviour(gen_server).

%%%----------------------------------------------------------------------------
%%% Exports
%%%----------------------------------------------------------------------------

-export([start/0, start_link/0, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([terminate/2, code_change/3]).
-export([stat_t/0, stat_t/1, add_stat_t/2, upd_stat_t/3, upd_stat_t/4, upd_stat_t/5]).
-export([reload_config_signal/0]).

%%%----------------------------------------------------------------------------
%%% Includes
%%%----------------------------------------------------------------------------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("kernel/include/file.hrl").

-include("ej_stat.hrl").
-include("job.hrl").
-include("amqp_client.hrl").

%%%----------------------------------------------------------------------------
%%% gen_server callbacks
%%%----------------------------------------------------------------------------
init(_) ->
    mpln_p_debug:ir({?MODULE, ?LINE, 'init...'}),
    C = ejobman_conf:get_config_stat(),
    New = prepare_all(C),
    process_flag(trap_exit, true), % to save storage
    erlang:send_after(?STAT_T, self(), periodic_check), % for redundancy
    mpln_p_debug:ir({?MODULE, ?LINE, 'init done'}),
    {ok, New, ?STAT_T}.

%------------------------------------------------------------------------------
-spec handle_call(any(), any(), #ejst{}) -> {stop, normal, ok, #ejst{}} | {reply, any(), #ejst{}}.
%%
%% Handling call messages
%% @since 2011-12-20 13:34
%%
handle_call(stop, _From, St) ->
    {stop, normal, ok, St};

handle_call(status, _From, St) ->
    {reply, St, St};

%% @doc returns time statistic
handle_call({stat_t, Type}, _From, St) ->
    Res = ejobman_print_stat:make_stat_t_info(St, Type),
    {reply, Res, St};

%% @doc set new debug level for facility
handle_call({set_debug_item, Facility, Level}, _From, St) ->
    % no api for this, use message passing
    New = mpln_misc_run:update_debug_level(St#ejst.debug, Facility, Level),
    {reply, St#ejst.debug, St#ejst{debug=New}};

handle_call(_Other, _From, St) ->
    mpln_p_debug:er({?MODULE, ?LINE, call_other, _Other}),
    {reply, {error, unknown_request}, St}.

%------------------------------------------------------------------------------
-spec handle_cast(any(), #ejst{}) -> any().
%%
%% Handling cast messages
%% @since 2011-12-20 13:34
%%
handle_cast(stop, St) ->
    {stop, normal, St};

handle_cast({add_job, Time, Tag}, St) ->
    add_job_stat(Time, Tag),
    {noreply, St};

handle_cast({upd_job, Time, Tag, Work, Queued, Worked}, St) ->
    upd_job_stat(Time, Tag, Work, Queued, Worked),
    {noreply, St};

handle_cast(reload_config_signal, St) ->
    New = process_reload_config(St),
    {noreply, New};

handle_cast(_Other, St) ->
    mpln_p_debug:er({?MODULE, ?LINE, cast_other, _Other}),
    {noreply, St}.

%------------------------------------------------------------------------------
terminate(_, State) ->
    mpln_p_debug:pr({?MODULE, terminate, ?LINE}, State#ejst.debug, run, 1),
    ok.

%------------------------------------------------------------------------------
-spec handle_info(any(), #ejst{}) -> any().
%%
%% Handling all non call/cast messages
%%
handle_info(timeout, State) ->
    mpln_p_debug:pr({?MODULE, 'info_timeout', ?LINE}, State#ejst.debug, run, 3),
    %New = periodic_check(State),
    {noreply, State};

handle_info(periodic_check, State) ->
    New = periodic_check(State),
    {noreply, New};

handle_info(_Req, State) ->
    mpln_p_debug:er({?MODULE, ?LINE, info_other, _Req}),
    {noreply, State}.

%------------------------------------------------------------------------------
code_change(_Old_vsn, State, _Extra) ->
    {ok, State}.

%%%----------------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------------
-spec start() -> any().
%%
%% @doc starts receiver gen_server
%% @since 2011-12-30 13:34
%%
start() ->
    start_link().

%%-----------------------------------------------------------------------------
%%
%% @doc starts receiver gen_server with pre-defined config
%% @since 2011-12-20 13:34
%%
-spec start_link() -> any().

start_link() ->
    start_link(?CONF).

%%
%% @doc starts receiver gen_server with given config
%% @since 2011-12-20 13:34
%%
-spec start_link(string()) -> any().

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Config], []).

%%-----------------------------------------------------------------------------
%%
%% @doc stops receiver gen_server
%% @since 2011-12-20 13:34
%%
-spec stop() -> any().

stop() ->
    gen_server:call(?MODULE, stop).

%%-----------------------------------------------------------------------------
%%
%% @doc asks ejobman_stat for time statistic
%% @since 2012-02-02 14:09
%%
-spec stat_t() -> string().

stat_t() ->
    stat_t(raw).

stat_t(Type) ->
    gen_server:call(?MODULE, {stat_t, Type}).

%%-----------------------------------------------------------------------------
%%
%% @doc api call to add time statistic
%% @since 2012-02-02 14:09
%%
-spec add_stat_t(tuple(), any()) -> ok.

add_stat_t(Time, Tag) ->
    gen_server:cast(?MODULE, {add_job, Time, Tag}).

%%
%% @doc api call to update time statistic
%% @since 2012-02-02 14:09
%%
-spec upd_stat_t(any(), non_neg_integer(), non_neg_integer()) -> ok.

upd_stat_t(Tag, Work, Queued) ->
    upd_stat_t(now(), Tag, Work, Queued).

-spec upd_stat_t(tuple(), any(), non_neg_integer(), non_neg_integer()) -> ok.

upd_stat_t(Time, Tag, Work, Queued) ->
    upd_stat_t(Time, Tag, Work, Queued, 0).

-spec upd_stat_t(tuple(), any(), non_neg_integer(), non_neg_integer(), non_neg_integer()) -> ok.

upd_stat_t(Time, Tag, Work, Queued, Worked) ->
    gen_server:cast(?MODULE, {upd_job, Time, Tag, Work, Queued, Worked}).

%%-----------------------------------------------------------------------------
%%
%% @doc send a message to the server to reload own config
%% @since 2012-03-02 14:49
%%
-spec reload_config_signal() -> ok.

reload_config_signal() ->
    gen_server:cast(?MODULE, reload_config_signal).

%%%----------------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------------
%%
%% @doc does all necessary preparations
%%
-spec prepare_all(#ejst{}) -> #ejst{}.

prepare_all(C) ->
    prepare_stat(C#ejst{start=now(), pid=self()}).
    
%%-----------------------------------------------------------------------------
%%
%% @doc prepares statistic
%%
prepare_stat(St) ->
    ets:new(?STAT_TAB_M, [named_table, set, protected, {keypos,1}]),
    ets:new(?STAT_TAB_H, [named_table, set, protected, {keypos,1}]),
    St.
%%-----------------------------------------------------------------------------
%%
%% @doc performs periodic checks, triggers timer for next periodic check
%%
-spec periodic_check(#ejst{}) -> #ejst{}.

periodic_check(#ejst{timer=Ref, clean_interval=T} = St) ->
    mpln_misc_run:cancel_timer(Ref),
    New = clean_old(St),
    Nref = erlang:send_after(T * 1000, self(), periodic_check),
    New#ejst{timer=Nref}.

%%-----------------------------------------------------------------------------
%%
%% @doc updates items in job statistic (minute and hourly)
%%
-spec upd_job_stat(tuple(), any(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
                          true.

upd_job_stat(Time, Tag, Work, Queued, Worked) ->
    upd_minute_job_stat(Time, Tag, Work, Queued, Worked),
    upd_hourly_job_stat(Time, Tag, Work, Queued, Worked).

upd_minute_job_stat(Time, Tag, Work, Queued, Worked) ->
    estat_misc:set_max_timed_stat(?STAT_TAB_M, 'minute', Time, {Tag, 'work'}, Work, Worked),
    estat_misc:set_max_timed_stat(?STAT_TAB_M, 'minute', Time, {Tag, 'queued'}, Queued, 0).

upd_hourly_job_stat(Time, Tag, Work, Queued, Worked) ->
    estat_misc:set_max_timed_stat(?STAT_TAB_H, 'hour', Time, {Tag, 'work'}, Work, Worked),
    estat_misc:set_max_timed_stat(?STAT_TAB_H, 'hour', Time, {Tag, 'queued'}, Queued, 0).


%%-----------------------------------------------------------------------------
%%
%% @doc adds item to job statistic (minute and hourly)
%%
-spec add_job_stat(tuple(), any()) -> true.

add_job_stat(Time, Tag) ->
    add_minute_job_stat(Time, Tag),
    add_hourly_job_stat(Time, Tag).

add_minute_job_stat(Time, Tag) ->
    estat_misc:add_timed_stat(?STAT_TAB_M, 'minute', Time, Tag).

add_hourly_job_stat(Time, Tag) ->
    estat_misc:add_timed_stat(?STAT_TAB_H, 'hour', Time, Tag).

%%-----------------------------------------------------------------------------
%%
%% @doc cleans old statistic and job info files
%%
-spec clean_old(#ejst{}) -> #ejst{}.

clean_old(St) ->
    clean_old_statistic(St),
    St.

clean_old_statistic(#ejst{stat_limit_cnt_h=Hlimit, stat_limit_cnt_m=Mlimit}) ->
    estat_misc:clean_timed_stat(?STAT_TAB_H, Hlimit*60*60),
    estat_misc:clean_timed_stat(?STAT_TAB_M, Mlimit*60).

%%-----------------------------------------------------------------------------
%%
%% @doc fetches config from updated environment and stores it in the state.
%%
-spec process_reload_config(#ejst{}) -> #ejst{}.

process_reload_config(_St) ->
    ejobman_conf:get_config_stat().

%%-----------------------------------------------------------------------------