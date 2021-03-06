%%%
%%% ejobman_receiver: job group handler
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
%%% @doc Receives messages from a RabbitMQ queue for one group,
%%% creates children to handle requests
%%% 

-module(ejobman_group_handler).
-behaviour(gen_server).

%%%----------------------------------------------------------------------------
%%% Exports
%%%----------------------------------------------------------------------------

-export([start/0, start_link/0, start_link/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([terminate/2, code_change/3]).
-export([send_ack/3]).
-export([cmd_result/5]).
-export([compose_group_name/1]).

%%%----------------------------------------------------------------------------
%%% Includes
%%%----------------------------------------------------------------------------

-include("group_handler.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include("rabbit_session.hrl").

%%%----------------------------------------------------------------------------
%%% gen_server callbacks
%%%----------------------------------------------------------------------------
init([List]) ->
    New = prepare_all(List),
    process_flag(trap_exit, true), % to perform amqp channel teardown
    mpln_p_debug:ir({?MODULE, 'init done', ?LINE, New#egh.id, New#egh.group}),
    {ok, New}.

%------------------------------------------------------------------------------
-spec handle_call(any(), any(), #egh{}) ->
                         {stop, normal, ok, #egh{}}
                         | {reply, any(), #egh{}}.
%%
%% Handling call messages
%% @since 2011-07-15 11:00
%%
handle_call(stop, _From, St) ->
    {stop, normal, ok, St};

handle_call(status, _From, St) ->
    {reply, St, St};

handle_call({set_debug_item, Facility, Level}, _From, St) ->
    % no api for this, use message passing
    New = mpln_misc_run:update_debug_level(St#egh.debug, Facility, Level),
    {reply, St#egh.debug, St#egh{debug=New}};

handle_call(_N, _From, St) ->
    mpln_p_debug:er({?MODULE, ?LINE, call_other, _N}),
    {reply, {error, unknown_request}, St}.

%------------------------------------------------------------------------------
-spec handle_cast(any(), #egh{}) ->
                         {stop, normal, #egh{}}
                             | {noreply, #egh{}}.
%%
%% Handling cast messages
%% @since 2011-07-15 11:00
%%
handle_cast(stop, St) ->
    {stop, normal, St};

handle_cast({cmd_result, Res, T1, T2, Id}, St) ->
    St_r = ejobman_group_handler_cmd:process_cmd_result(St, Id, Res),
    New = ejobman_group_handler_cmd:do_waiting_jobs(St_r),
    {noreply, New};

handle_cast({send_ack, Id, Tag}, #egh{conn=Conn} = St) ->
    Res = ejobman_rb:send_ack(Conn, Tag),
    {noreply, St};

handle_cast(_Other, St) ->
    mpln_p_debug:er({?MODULE, ?LINE, cast_other, _Other}),
    {noreply, St}.

%------------------------------------------------------------------------------
terminate(Reason, #egh{group=Group, conn=Conn}) ->
    ejobman_rb:teardown_channel(Conn),
    mpln_p_debug:er({?MODULE, ?LINE, terminate, Group, Reason}),
    ok.

%------------------------------------------------------------------------------
-spec handle_info(any(), #egh{}) -> any().
%%
%% Handling all non call/cast messages
%%
handle_info(timeout, #egh{id=Id, group=Group}=State) ->
    mpln_p_debug:pr({?MODULE, 'handle_info timeout', ?LINE, Id, Group}, State#egh.debug, run, 6),
    {noreply, State};

handle_info({#'basic.deliver'{delivery_tag=Tag}, Content} = _Req, #egh{id=Id, group=Group} = State) ->
    mpln_p_debug:pr({?MODULE, 'basic.deliver', ?LINE, Id, _Req}, State#egh.debug, msg, 3),
    Payload = Content#amqp_msg.payload,
    Props = Content#amqp_msg.props,
    Sid = ejobman_rb:get_prop_id(Props),
    Timestamp = ejobman_rb:get_timestamp(Props),
    erpher_et:trace_me(50, {?MODULE, Group}, 'group_queue', 'receive', {Id, Sid, Content}),
    New = ejobman_group_handler_cmd:store_rabbit_cmd(State, Tag, Sid, Payload, Timestamp),
    {noreply, New};

handle_info(#'basic.consume_ok'{consumer_tag = _Tag}, State) ->
    %New = ejobman_receiver_cmd:store_consumer_tag(State, Tag),
    {noreply, State};

handle_info({'EXIT', Process, Reason}, _State) ->
    mpln_p_debug:er({?MODULE, ?LINE, 'Trap exit', Process, Reason}),
    {'EXIT', Reason};

handle_info(_Req, State) ->
    mpln_p_debug:er({?MODULE, 'handle_info unknown', ?LINE, _Req}),
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
%% @since 2011-07-15 10:00
%%
start() ->
    start_link().

%%-----------------------------------------------------------------------------
%%
%% @doc starts receiver gen_server with pre-defined config
%% @since 2011-07-15 10:00
%%
-spec start_link() -> any().

start_link() ->
    start_link(?CONF).

%%
%% @doc starts gen_server with given config
%% @since 2011-07-15 10:00
%%
-spec start_link(list()) -> any().

start_link(Config) ->
    gen_server:start_link(?MODULE, [Config], []).

%%-----------------------------------------------------------------------------
%%
%% @doc stops group handler
%% @since 2011-07-15 10:00
%%
-spec stop(pid()) -> any().

stop(Pid) ->
    gen_server:call(Pid, stop).

%%-----------------------------------------------------------------------------
%%
%% @doc sends request to send acknowledge to amqp.
%% @since 2011-12-02 16:16
%%
-spec send_ack(pid(), reference() | binary(), any()) -> ok.

send_ack(Pid, Id, Tag) ->
    gen_server:cast(Pid, {send_ack, Id, Tag}).

%%-----------------------------------------------------------------------------
%%
%% @doc sends result id to the server
%% @since 2012-01-12 12:39
%%
-spec cmd_result(pid(), tuple(), tuple(), tuple(), reference() | binary()) ->
                        ok.

cmd_result(Pid, Res, T1, T2, Id) ->
    gen_server:cast(Pid, {cmd_result, Res, T1, T2, Id}).

%%%----------------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------------
%%
%% @doc does all the necessary preparations
%% @since 2011-07-15
%%
-spec prepare_all(list()) -> #egh{}.

prepare_all(List) ->
    C = ejobman_conf:get_config_group_handler(List),
    C_conn = get_connection(C),
    C_st = prepare_storage(C_conn),
    prepare_q(C_st).

%%-----------------------------------------------------------------------------
%%
%% @doc prepares internal queue
%%
-spec prepare_storage(#egh{}) -> #egh{}.

prepare_storage(C) ->
    C#egh{ch_queue=queue:new()}.

%%-----------------------------------------------------------------------------
%%
%% @doc asks ejobman_receiver for vhost and connection
%%
-spec get_connection(#egh{}) -> #egh{}.

get_connection(C) ->
    {Vhost, Conn} = ejobman_receiver:get_conn_params(),
    C#egh{vhost=Vhost, conn=Conn}.

%%-----------------------------------------------------------------------------
%%
%% @doc prepares RabbitMQ: exchange, queue, consumer
%% @since 2011-07-15
%%
-spec prepare_q(#egh{}) -> #egh{}.

prepare_q(#egh{group=Gid} = C) ->
    {ok, #conn{connection=Connection} = Conn} = ejobman_rb:start_channel(C#egh.conn, C#egh.vhost),
    erlang:link(Connection),
    ejobman_rb:channel_qos(Conn, 0, 1),
    Exchange = Queue = Key = compose_group_name(Gid),
    ejobman_rb:create_exchange(Conn, Exchange, <<"direct">>),
    ejobman_rb:create_queue(Conn, Queue),
    ejobman_rb:bind_queue(Conn, Queue, Exchange, Key),
    New_conn = ejobman_rb:setup_consumer(Conn, Queue),
    ejobman_receiver:tell_group(Gid, Exchange, Key),
    C#egh{conn = New_conn, exchange=Exchange, queue=Queue}.

%%-----------------------------------------------------------------------------
%%
%% @doc composes a binary group name
%%
compose_group_name(Gid) ->
    Bin = mpln_misc_web:make_binary(Gid),
    << <<"ejobman_group_">>/binary, Bin/binary>>.

%%-----------------------------------------------------------------------------
