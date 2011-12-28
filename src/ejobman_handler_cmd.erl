%%%
%%% ejobman_handler_cmd: received command handling
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
%%% @since 2011-07-15 10:00
%%% @license MIT
%%% @doc functions that do real handling of the command received by
%%% ejobman_handler
%%%

-module(ejobman_handler_cmd).

%%%----------------------------------------------------------------------------
%%% Exports
%%%----------------------------------------------------------------------------

-export([do_command/3, do_short_commands/1]).
-export([do_command_result/6]).
-export([remove_child/3]).

%%%----------------------------------------------------------------------------
%%% Includes
%%%----------------------------------------------------------------------------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("ejobman.hrl").
-include("job.hrl").

%%%----------------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------------
%%
%% @doc stores the command into a queue and goes to command processing
%% @since 2011-07-15 10:00
%%
-spec do_command(#ejm{}, any(), #job{}) -> #ejm{}.

do_command(St, From, Job) ->
    mpln_p_debug:pr({?MODULE, "do_command", ?LINE, From, Job},
        St#ejm.debug, job, 5),
    Job_r = fill_id(Job),
    St_q = store_in_ch_queue(St, From, Job_r),
    St_st = add_cmd_stat(St_q, Job_r),
    St_st2 = check_cmd_stat(St_st),
    do_short_commands(St_st2).

%%-----------------------------------------------------------------------------
%%
%% @doc iterates over all short commands queues
%% @since 2011-11-14 17:14
%%
-spec do_short_commands(#ejm{}) -> #ejm{}.

do_short_commands(#ejm{ch_queues=Data} = St) ->
    F = fun(Gid, _, Acc) ->
        mpln_p_debug:pr({?MODULE, "do_short_command", ?LINE, Gid},
            St#ejm.debug, job_queue, 3),
        short_command_step(Acc, Gid)
    end,
    dict:fold(F, St, Data).

%%-----------------------------------------------------------------------------
%%
%% @doc sends ack for job to amqp, removes the child from the list of
%% children, logs a command result to the job log
%% @since 2011-10-19 18:00
%%
-spec do_command_result(#ejm{}, tuple(), tuple(), tuple(),
    default | binary(), reference()) -> #ejm{}.

do_command_result(St, Res, T1, T2, Group, Id) ->
    Dur = timer:now_diff(T2, T1),
    mpln_p_debug:pr({?MODULE, 'do_command_result', ?LINE, Group, Id, Dur, Res},
        St#ejm.debug, run, 4),
    Now = now(),
    Start_c = fetch_start_time(St, Group, Id),
    St_st = res_cmd_stat(St, Res, Start_c, T1, T2, Id, Now),
    log_child_duration(St_st, Group, Id, Now),
    St_st.

%%-----------------------------------------------------------------------------
%%
%% @doc removes child from the list of children
%% @since 2011-11-14 17:14
%%
-spec remove_child(#ejm{}, pid(), any()) -> #ejm{}.

remove_child(St, Pid, Group) ->
    Ch = fetch_spawned_children(St, Group),
    F = fun(#chi{pid=X}) when X == Pid ->
            false;
        (_) ->
            true
    end,
    New_ch = lists:filter(F, Ch),
    St_s = store_spawned_children(St, Group, New_ch),
    update_stat_t_result(St_s, Group, New_ch).

%%%----------------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------------
%%
%% @doc logs duration for children
%%
log_child_duration(St, Group, Id, Now) ->
    Ch = fetch_spawned_children(St, Group),
    F = fun(#chi{id=X}) when X == Id ->
            true;
        (_) ->
            false
    end,
    Term = lists:filter(F, Ch),
    F2 = fun(#chi{id=Id2, start=T}) ->
        Dur = timer:now_diff(Now, T),
        mpln_p_debug:pr({?MODULE, 'log_child_duration', ?LINE, Group, Id2, Dur},
            St#ejm.debug, run, 2)
    end,
    lists:foreach(F2, Term).

%%-----------------------------------------------------------------------------
%%
%% @doc does one iteration for given group over queue and spawned children.
%% Returns updated state with new queue and spawned children
%%
-spec short_command_step(#ejm{}, any()) -> #ejm{}.

short_command_step(#ejm{job_groups=Groups, max_children=Max} = St, Gid) ->
    Q = fetch_job_queue(St, Gid),
    Ch = fetch_spawned_children(St, Gid),
    G_max = get_group_max(Groups, Gid, Max),
    {New_q, New_ch} = do_short_command_queue(St, {Q, Ch}, Gid, G_max),
    St_j = store_job_queue(St, Gid, New_q, New_ch),
    St_ch = store_spawned_children(St_j, Gid, New_ch),
    St_ch.

%%-----------------------------------------------------------------------------
%%
%% @doc stores a queue for the given group to a dictionary. If the queue is
%% empty then erases it completely from the dictionary.
%%
-spec store_job_queue(#ejm{}, any(), undefined | queue(), list()) -> #ejm{}.

store_job_queue(#ejm{ch_queues=Data} = St, Gid, undefined, Ch) ->
    New_dict = dict:erase(Gid, Data),
    St_u = update_stat_t(St, Gid, Ch, 0),
    St_u#ejm{ch_queues=New_dict};

store_job_queue(#ejm{ch_queues=Data} = St, Gid, Q, Ch) ->
    New_dict = dict:store(Gid, Q, Data),
    St_u = update_stat_t(St, Gid, Ch, queue:len(Q)),
    St_u#ejm{ch_queues=New_dict}.

%%-----------------------------------------------------------------------------
%%
%% @doc updates time statistic for the given group
%%
-spec update_stat_t(#ejm{}, any(), list(), non_neg_integer()) -> #ejm{}.

update_stat_t(St, Group, Ch, N) ->
    Now = now(),
    St_m = update_stat_t_minute(St, Group, Ch, N, Now),
    St_h = update_stat_t_hour(St_m, Group, Ch, N, Now),
    clean_stat_t(St_h).

%%-----------------------------------------------------------------------------
%%
%% @doc updates time statistic for the given group on job termination
%%
-spec update_stat_t_result(#ejm{}, any(), list()) -> #ejm{}.

update_stat_t_result(St, Group, Ch) ->
    Now = now(),
    St_m = update_stat_t_result_minute(St, Group, Ch, Now),
    update_stat_t_result_hour(St_m, Group, Ch, Now).

%%-----------------------------------------------------------------------------
%%
%% @doc updates hour time statistic for the given group on job termination
%%
update_stat_t_result_hour(#ejm{stat_t=Stat} = St, Group, Ch, Now) ->
    Len = length(Ch),
    T = mpln_misc_time:short_time(Now, hour),
    Key = {T, Group},
    {_W_cur, W_max, Q_cur, Q_max} =
        case dict:find(Key, Stat#stat_t.h) of
            {ok, Item} ->
                Item;
            _ ->
                {Len, Len, 0, 0}
        end,
    New_item = {Len, W_max, Q_cur, Q_max},
    New_hdata = dict:store(Key, New_item, Stat#stat_t.h),
    New_stat = Stat#stat_t{h=New_hdata},
    St#ejm{stat_t = New_stat}.

%%-----------------------------------------------------------------------------
%%
%% @doc updates minute time statistic for the given group on job termination
%%
update_stat_t_result_minute(#ejm{stat_t=Stat} = St, Group, Ch, Now) ->
    Len = length(Ch),
    T = mpln_misc_time:short_time(Now, minute),
    Key = {T, Group},
    {_W_cur, W_max, Q_cur, Q_max} =
        case dict:find(Key, Stat#stat_t.m) of
            {ok, Item} ->
                Item;
            _ ->
                {Len, Len, 0, 0}
        end,
    New_item = {Len, W_max, Q_cur, Q_max},
    New_mdata = dict:store(Key, New_item, Stat#stat_t.m),
    New_stat = Stat#stat_t{m=New_mdata},
    St#ejm{stat_t = New_stat}.

%%-----------------------------------------------------------------------------
%%
%% @doc cleans old time statistic data
%%
-spec clean_stat_t(#ejm{}) -> #ejm{}.

clean_stat_t(St) ->
    St_m = clean_stat_t(St, minute),
    clean_stat_t(St_m, hour).

-spec clean_stat_t(#ejm{}, minute | hour) -> #ejm{}.

clean_stat_t(#ejm{stat_t=Stat} = St, minute) ->
    New_data = proceed_clean_stat_t(Stat#stat_t.m, ?STAT_T_KEEP_MINUTES),
    New_stat = Stat#stat_t{m=New_data},
    St#ejm{stat_t = New_stat};

clean_stat_t(#ejm{stat_t=Stat} = St, hour) ->
    New_data = proceed_clean_stat_t(Stat#stat_t.h, ?STAT_T_KEEP_HOURS),
    New_stat = Stat#stat_t{h=New_data},
    St#ejm{stat_t = New_stat}.

-spec proceed_clean_stat_t(dict(), non_neg_integer()) -> dict().

proceed_clean_stat_t(Data, Keep) ->
    Size = dict:size(Data),
    L1 = dict:fetch_keys(Data),
    L2 = lists:sort(L1),
    Len_to_del = erlang:max(Size - Keep, 0),
    List_to_del = lists:sublist(L2, 1, Len_to_del),
    New_data = lists:foldl(
                  fun(X, Acc) ->
                          dict:erase(X, Acc)
                  end,
                  Data, List_to_del),
    New_data.

%%-----------------------------------------------------------------------------
%%
%% @doc updates minute statistic for given group
%%
-spec update_stat_t_minute(#ejm{}, any(), list(), non_neg_integer(), tuple())
                          -> #ejm{}.

update_stat_t_minute(#ejm{stat_t=Stat} = St, Group, Ch, N, Now) ->
    Len = length(Ch),
    T = mpln_misc_time:short_time(Now, minute),
    Key = {T, Group},
    {_W_cur, W_max, _Q_cur, Q_max} =
        case dict:find(Key, Stat#stat_t.m) of
            {ok, Item} ->
                Item;
            _ ->
                {0, 0, 0, 0}
        end,
    New_item = {Len, erlang:max(Len, W_max), N, erlang:max(N, Q_max)},
    New_mdata = dict:store(Key, New_item, Stat#stat_t.m),
    New_stat = Stat#stat_t{m=New_mdata},
    St#ejm{stat_t = New_stat}.

%%-----------------------------------------------------------------------------
%%
%% @doc updates hour statistic for given group
%%
-spec update_stat_t_hour(#ejm{}, any(), list(), non_neg_integer(), tuple()) ->
                                #ejm{}.

update_stat_t_hour(#ejm{stat_t=Stat} = St, Group, Ch, N, Now) ->
    Len = length(Ch),
    T = mpln_misc_time:short_time(Now, hour),
    Key = {T, Group},
    {_W_cur, W_max, _Q_cur, Q_max} =
        case dict:find(Key, Stat#stat_t.h) of
            {ok, Item} ->
                Item;
            _ ->
                {0, 0, 0, 0}
        end,
    New_item = {Len, erlang:max(Len, W_max), N, erlang:max(N, Q_max)},
    New_hdata = dict:store(Key, New_item, Stat#stat_t.h),
    New_stat = Stat#stat_t{h=New_hdata},
    St#ejm{stat_t = New_stat}.

%%-----------------------------------------------------------------------------
%%
%% @doc fetches particular queue from dict of queues or creates empty one
%%
-spec fetch_job_queue(#ejm{}, any()) -> queue().

fetch_job_queue(#ejm{ch_queues=Data}, Gid) ->
    case dict:find(Gid, Data) of
        {ok, Q} ->
            Q;
        _ ->
            queue:new()
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc stores a children list for the given group to a dictionary
%%
-spec store_spawned_children(#ejm{}, any(), list()) -> #ejm{}.

store_spawned_children(#ejm{ch_data=Data} = St, Gid, Ch) ->
    New_dict = dict:store(Gid, Ch, Data),
    St#ejm{ch_data=New_dict}.

%%-----------------------------------------------------------------------------
%%
%% @doc fetches particular list from dict of lists or creates empty one
%%
-spec fetch_spawned_children(#ejm{}, any()) -> list().

fetch_spawned_children(#ejm{ch_data=Data}, Gid) ->
    case dict:find(Gid, Data) of
        {ok, L} ->
            L;
        _ ->
            []
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc repeatedly calls for creating new child for the given queue
%% until either limit is reached or command queue exhausted.
%% Returns updated queue and spawned children list.
%% @since 2011-07-22 14:54
%%
-spec do_short_command_queue(#ejm{}, {Q, L}, any(), non_neg_integer()) ->
    {undefined | Q, L}.

do_short_command_queue(St, {Q, Ch}, Gid, Max) ->
    Len = length(Ch),
    mpln_p_debug:pr({?MODULE, "do_short_command_queue", ?LINE, Gid, Len, Max},
        St#ejm.debug, handler_run, 4),
    mpln_p_debug:pr({?MODULE, "do_short_command_queue queue", ?LINE,
        Gid, Q, Ch}, St#ejm.debug, job_queue, 5),
    case queue:is_empty(Q) of
        false when Len < Max ->
            New_dat = check_one_command(St, {Q, Ch}, {Gid, Len, Max}),
            do_short_command_queue(St, New_dat, Gid, Max);
        false ->
            Qlen = queue:len(Q),
            mpln_p_debug:pr({?MODULE,
                "do_short_command_queue too many children",
                ?LINE, Gid, Qlen, Len, Max}, St#ejm.debug, handler_run, 2),
            {Q, Ch};
        _ ->
            mpln_p_debug:pr({?MODULE, "do_short_command_queue no new child",
                ?LINE, Gid, Len, Max}, St#ejm.debug, handler_run, 4),
            {undefined, Ch}
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc returns configured max_children for the given group or default
%%
-spec get_group_max(list(), any(), non_neg_integer()) -> non_neg_integer().

get_group_max(Groups, Gid, Default) ->
    L2 = [X || X <- Groups,
        X#jgroup.id == Gid, is_integer(X#jgroup.max_children)],
    case L2 of
        [I | _] ->
            I#jgroup.max_children;
        _ ->
            Default
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc adds job to the last jobs statistic
%%
-spec add_cmd_stat(#ejm{}, #job{}) -> #ejm{}.

add_cmd_stat(#ejm{stat_r=Stat} = St, #job{id=Id} = Job_src) ->
    Path = make_path(Job_src),
    Job = Job_src#job{auth=undefined, path=Path},
    Now = now(),
    Info = #jst{job=Job, status=queued, start=Now, time=Now},
    New = dict:store(Id, Info, Stat),
    St#ejm{stat_r=New}.

%%-----------------------------------------------------------------------------
%%
%% @doc marks job as "request done" in the last jobs
%%
res_cmd_stat(#ejm{stat_r=Stat} = St, Res, Start_c, Ht1, Ht2, Id, Now) ->
    Dur = timer:now_diff(Ht2, Ht1),
    Rc = make_title(Res),
    New_info = 
        case dict:find(Id, Stat) of
            {ok, Info} ->
                Time = Info#jst.start,
                Info#jst{result=Rc, result_full=Res, status=done, time=Now,
                    t_start_child=Start_c, t_stop_child=Now,
                    t_start_req=Ht1, t_stop_req=Ht2,
                    dur_req=Dur, dur_all=timer:now_diff(Now, Time)};
            error ->
                % too old job was removed from stat_r
                mpln_p_debug:pr({?MODULE, 'res_cmd_stat', ?LINE, 'error',
                    Id, Dur}, St#ejm.debug, run, 3),
                Time = now(), % this gives negative duration, so keep an eye
                #jst{result=Rc, result_full=Res, status=done, time=Now,
                    t_start_child=Start_c, t_stop_child=Now,
                    t_start_req=Ht1, t_stop_req=Ht2,
                    dur_req=Dur, dur_all=timer:now_diff(Now, Time)}
        end,
    New_stat = dict:store(Id, New_info, Stat),
    St#ejm{stat_r=New_stat}.

%%-----------------------------------------------------------------------------
%%
%% @doc fetches start time for the given job id and group
%%
fetch_start_time(St, Group, Id) ->
    Ch = fetch_spawned_children(St, Group),
    F = fun(#chi{id=X}) ->
            X =/= Id
        end,
    Res = lists:dropwhile(F, Ch),
    case Res of
        [] ->
            mpln_p_debug:pr({?MODULE, 'fetch_start_time', ?LINE,
                'no start time', Group, Id}, St#ejm.debug, run, 0),
            {0,0,0};
        [Item | _] ->
            Item#chi.start
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc extracts path from the full url
%%
make_path(#job{url=Url}) ->
    Str = mpln_misc_web:make_string(Url),
    case http_uri:parse(Str) of
        {error, _Reason} ->
            "";
        {_Scheme, _Auth, _Host, _Port, Path, _Query} ->
            Path
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc extracts code and reason from a result tuple
%%
make_title({ok, {Scode, _Body}}) ->
    {ok, Scode};
make_title({ok, {Stline, _Hdr, _Body}}) ->
    {ok, Stline};
make_title({error, Reason}) ->
    {error, Reason}.

%%-----------------------------------------------------------------------------
%%
%% @doc checks whether the stat size above the limit and cleans it
%% if necessary
%%
check_cmd_stat(#ejm{stat_r=Stat, stat_limit_n=Limit} = St) ->
    Size = dict:size(Stat),
    if  Size > Limit ->
            clean_ext_cmd_stat(St);
        true ->
            St
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc cleans extra jobs (cut the list up to limit, -10% - 10) from the last
%% jobs statistic
%%
-spec clean_ext_cmd_stat(#ejm{}) -> #ejm{}.

clean_ext_cmd_stat(#ejm{stat_r=Stat, stat_limit_n=Limit} = St) ->
    Size = dict:size(Stat),
    L1 = dict:fetch_keys(Stat),
    L2 = lists:reverse(lists:sort(L1)),
    Num = abs(Size - trunc(Limit/10) - 10),
    L3 =
        if  Num =< Size ->
                {_, Tmp} = lists:split(Num, L2), % get list to delete
                Tmp;
            true ->
                L2
        end,
    mpln_p_debug:pr({?MODULE, clean_ext_cmd_stat, ?LINE, Size, Num, Limit},
        St#ejm.debug, stat, 4),
    mpln_p_debug:pr({?MODULE, clean_ext_cmd_stat, ?LINE, L3},
        St#ejm.debug, stat, 5),
    New = lists:foldl(
        fun(X, Acc) ->
            dict:erase(X, Acc)
        end,
        Stat, L3),
    St#ejm{stat_r=New}.

%%-----------------------------------------------------------------------------
%%
%% @doc stores a command into a queue for the given group for later processing.
%% @since 2011-07-22 10:00
%%
-spec store_in_ch_queue(#ejm{}, any(), #job{}) -> #ejm{}.

store_in_ch_queue(St, From, Job) ->
    {Q, Job_g} = fetch_queue(St, Job),
    New_q = queue:in({From, Job_g}, Q),
    mpln_p_debug:pr({?MODULE, 'store_in_ch_queue', ?LINE,
        Job_g#job.id, Job_g#job.group}, St#ejm.debug, job_queue, 2),
    mpln_p_debug:pr({?MODULE, 'store_in_ch_queue', ?LINE, New_q},
        St#ejm.debug, job_queue, 4),
    store_queue(St, Job_g#job.group, New_q).

%%-----------------------------------------------------------------------------
%%
%% @doc stores the given queue in a dictionary using the given group
%%
-spec store_queue(#ejm{}, default | any(), queue()) -> #ejm{}.

store_queue(#ejm{ch_queues=Data} = St, Gid, Q) ->
    New_data = dict:store(Gid, Q, Data),
    St#ejm{ch_queues=New_data}.

%%-----------------------------------------------------------------------------
%%
%% @doc fetches queue from the state for given job group. Returns queue and
%% job with group data filled
%%
-spec fetch_queue(#ejm{}, #job{}) -> {queue(), #job{}}.

fetch_queue(#ejm{ch_queues=Data} = St, #job{group=Gid} = Job) ->
    Allowed = get_allowed_group(St, Gid),
    case dict:find(Allowed, Data) of
        {ok, Q} ->
            {Q, Job#job{group=Allowed}};
        _ ->
            {queue:new(), Job#job{group=Allowed}}
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc checks whether the group configured. Returns either the configured
%% value or atom 'default'
%%
get_allowed_group(#ejm{job_groups=L}, Gid) ->
    F = fun(#jgroup{id=Id}) when Id == Gid ->
            true;
        (_) ->
            false
    end,
    case lists:any(F, L) of
        true ->
            Gid;
        false ->
            default
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc checks for a queued command and calls do_one_command for processing
%% if any. Otherwise returns old queue and spawned children.
%% @since 2011-07-22 10:00
%%
-spec check_one_command(#ejm{}, {Q, L}, tuple()) -> {Q, L}.

check_one_command(St, {Q, Ch}, {Gid, Len, Max}) ->
    mpln_p_debug:pr({?MODULE, 'check_one_command', ?LINE},
                    St#ejm.debug, handler_run, 4),
    case queue:out(Q) of
        {{value, Item}, Q2} ->
            {_, J} = Item,
            ejobman_stat:add(J#job.id, 'from_queue',
                             [{max, Max}, {running, Len},
                              {queued, queue:len(Q)}, {group, Gid}]),
            New_ch = do_one_command(St, Ch, Item),
            {Q2, New_ch};
        _ ->
            {Q, Ch}
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc does command processing in background then sends reply to the client.
%% Returns modified children list with a new child if the one is created.
%% @since 2011-07-15 10:00
%%
-spec do_one_command(#ejm{}, [C], {any(), #job{}}) -> [C].

do_one_command(St, Ch, {From, J}) ->
    mpln_p_debug:pr({?MODULE, 'do_one_command_cmd job_id', ?LINE, J#job.id},
        St#ejm.debug, handler_child, 2),
    mpln_p_debug:pr({?MODULE, 'do_one_command_cmd', ?LINE, From, J},
        St#ejm.debug, handler_child, 3),
    % parameters for ejobman_child
    Child_params = [
        {http_connect_timeout, St#ejm.http_connect_timeout},
        {http_timeout, St#ejm.http_timeout},
        {schema_rewrite, St#ejm.schema_rewrite},
        {url_rewrite, St#ejm.url_rewrite},
        {from, From},
        {id, J#job.id},
        {tag, J#job.tag},
        {group, J#job.group},
        {method, J#job.method},
        {url, J#job.url},
        {host, J#job.host},
        {ip, J#job.ip},
        {params, J#job.params},
        {auth, J#job.auth},
        {debug, St#ejm.debug}
        ],
    mpln_p_debug:pr({?MODULE, 'do_one_command child params', ?LINE,
        Child_params}, St#ejm.debug, handler_child, 4),
    Res = supervisor:start_child(ejobman_child_supervisor, [Child_params]),
    mpln_p_debug:pr({?MODULE, 'do_one_command_res', ?LINE, Res},
        St#ejm.debug, handler_child, 5),
    case Res of
        {ok, Pid} ->
            add_child(Ch, Pid, J#job.id, J#job.tag);
        {ok, Pid, _Info} ->
            add_child(Ch, Pid, J#job.id, J#job.tag);
        _ ->
            Now = now(),
            ejobman_handler:cmd_result(Res, Now, Now, J#job.group, J#job.id),
            mpln_p_debug:pr({?MODULE, 'do_one_command_res', ?LINE, 'error',
                J#job.id, J#job.group, Res}, St#ejm.debug, handler_child, 1),
            Ch
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc adds child's pid to the list for later use
%% (e.g.: assign a job, send ack to rabbit, kill, rip, etc...)
%%
-spec add_child([#chi{}], pid(), reference(), binary()) -> [#chi{}].

add_child(Children, Pid, Id, Tag) ->
    Ch = #chi{pid = Pid, id = Id, start = now(), tag = Tag},
    [Ch | Children].

%%-----------------------------------------------------------------------------
%%
%% @doc fills id for job if it is undefined
%%
fill_id(#job{id=undefined} = Job) ->
    Job#job{id=make_ref()};
fill_id(Job) ->
    Job.

%%%----------------------------------------------------------------------------
%%% EUnit tests
%%%----------------------------------------------------------------------------
-ifdef(TEST).

make_test_req() ->
    make_test_req(1).

make_test_req(N) ->
    Pid = self(),
    From = {Pid, 'tag'},
    Method = "head",
    Url = "http://localhost:8182/?page" ++ pid_to_list(Pid) ++
        integer_to_list(N),
    {From, Method, Url}.

make_test_req2() ->
    make_test_req2(1).

make_test_req2(N) ->
    Pid = self(),
    From = {Pid, 'tag'},
    Method = "get",
    Rnd = crypto:rand_uniform(0, 100),
    Url = lists:flatten(io_lib:format(
        "http://localhost:8184/lp.yaws?new_id=~p&ref=~p", [N, Rnd])),
    Job = #job{method = Method, url = Url},
    %?debugFmt("make_test_req2: ~p, ~p~n~p~n", [N, Rnd, Job]),
    {From, Job}.

make_test_st({Pid, _}) ->
    K = "key1",
    Ch = [#chi{pid=Pid, start=now()}],
    #ejm{
        ch_data = dict:store(K, Ch, dict:new()),
        http_connect_timeout = 15002,
        http_timeout = 15003,
        max_children = 1,
        url_rewrite = [],
        job_groups = [
            [
            {name, "g1"},
            {max_children, 1}
            ],
            [
            {name, "g2"},
            {max_children, 2}
            ],
            [
            {name, "g3"},
            {max_children, 3}
            ]
        ],
        debug = [
            {config, 6},
            {handler_child, 6},
            {handler_run, 6},
            {run, 6},
            {http, 6}
        ],
        ch_queues = dict:new()
    }.

make_test_data() ->
    {From, Method, Url} = make_test_req(),
    St = make_test_st(From),
    {St, From, Method, Url}
.

make_test_data2() ->
    {From, Job} = make_test_req2(),
    St = make_test_st(From),
    {St, From, Job}
.

store_in_ch_queue_test() ->
    {St, From, Job} = make_test_data2(),
    New = store_in_ch_queue(St, From, Job),
    %?debugFmt("~p", [New]),
    Q_in = queue:in(
        {From, Job#job{group=default}},
        queue:new()),
    Stq = St#ejm{
        ch_queues = dict:store(default, Q_in, dict:new())
            },
    %?debugFmt("~p", [Stq]),
    ?assert(Stq =:= New).

do_command_test() ->
    {St, From, Job} = make_test_data2(),
    %?debugFmt("~p", [St]),
    New = do_command(St, From, Job),
    %?debugFmt("~p", [New]),
    Q_in = queue:in(
        {From, Job#job{group=default}},
        queue:new()),
    Stq = St#ejm{
        ch_queues = dict:store(default, Q_in, dict:new()),
        ch_data = dict:store(default, queue:new(), dict:new())
            },
    %?debugFmt("~p", [Stq]),
    ?assert(Stq =:= New).

do_command2_test() ->
    {St, _From, _Method, _Url} = make_test_data(),
    %?debugFmt("do_command2_test 1:~n~p~n", [St]),
    {F2, J2} = make_test_req2(2),
    {F3, J3} = make_test_req2(3),
    {F4, J4} = make_test_req2(4),
    {F5, J5} = make_test_req2(5),
    St2 = store_in_ch_queue(St , F2, J2),
    %?debugFmt("do_command2_test 2:~n~p~n", [St2]),
    St3 = store_in_ch_queue(St2, F3, J3),
    %?debugFmt("do_command2_test 3:~n~p~n", [St3]),
    St4 = store_in_ch_queue(St3, F4, J4),
    %?debugFmt("do_command2_test 4:~n~p~n", [St4]),
    St5 = store_in_ch_queue(St4, F5, J5),
    %?debugFmt("do_command2_test 5:~n~p~n", [St5]),
    _Res = do_short_commands(St5),
    %mpln_p_debug:pr({?MODULE, 'do_command2_test res', ?LINE, Res}, [], run, 0),
    ok.

-endif.
%%-----------------------------------------------------------------------------
