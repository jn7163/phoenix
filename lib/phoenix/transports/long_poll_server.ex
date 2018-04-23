defmodule Phoenix.Transports.LongPoll.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(options) do
    Supervisor.start_link(__MODULE__, [], options)
  end

  def init([]) do
    children = [
      worker(Phoenix.Transports.LongPoll.Server, [], restart: :temporary)
    ]
    supervise(children, strategy: :simple_one_for_one)
  end
end

defmodule Phoenix.Transports.LongPoll.Server do
  @moduledoc false

  use GenServer

  alias Phoenix.PubSub
  alias Phoenix.Socket.Transport

  @doc """
  Starts the Server.

    * `socket` - The `Phoenix.Socket` struct returned from `connect/2`
      of the socket handler.
    * `window_ms` - The longpoll session timeout, in milliseconds

  If the server receives no message within `window_ms`, it terminates
  and clients are responsible for opening a new session.
  """
  def start_link(endpoint, handler, transport_name, transport,
                 serializer, params, window_ms, priv_topic) do
    GenServer.start_link(__MODULE__, [endpoint, handler, transport_name, transport,
                                      serializer, params, window_ms, priv_topic])
  end

  ## Callbacks

  def init([endpoint, handler, transport_name, transport,
            serializer, params, window_ms, priv_topic]) do
    case Transport.connect(endpoint, handler, transport_name, transport, serializer, params) do
      {:ok, state} ->
        {:ok, state} = handler.init(state)

        state = %{
          buffer: [],
          handler: {handler, state},
          window_ms: trunc(window_ms * 1.5),
          pubsub_server: endpoint.__pubsub_server__(),
          priv_topic: priv_topic,
          last_client_poll: now_ms(),
          client_ref: nil
        }

        :ok = PubSub.subscribe(state.pubsub_server, priv_topic, link: true)
        schedule_inactive_shutdown(state.window_ms)
        {:ok, state}
      :error ->
        :ignore
    end
  end

  def handle_info({:dispatch, client_ref, body, ref}, state) do
    %{handler: {handler, handler_state}} = state

    case handler.handle_in({body, []}, handler_state) do
      {:reply, status, {_, reply}, handler_state} ->
        state = %{state | handler: {handler, handler_state}}
        status = if status == :ok, do: :ok, else: :error
        broadcast_from!(state, client_ref, {status, ref})
        publish_reply(state, reply)

      {:ok, handler_state} ->
        state = %{state | handler: {handler, handler_state}}
        broadcast_from!(state, client_ref, {:ok, ref})
        {:noreply, state}

      {:stop, reason, handler_state} ->
        state = %{state | handler: {handler, handler_state}}
        broadcast_from!(state, client_ref, {:error, ref})
        {:stop, reason, state}
    end
  end

  def handle_info({:subscribe, client_ref, ref}, state) do
    broadcast_from!(state, client_ref, {:subscribe, ref})
    {:noreply, state}
  end

  def handle_info({:flush, client_ref, ref}, state) do
    case state.buffer do
      [] ->
        {:noreply, %{state | client_ref: {client_ref, ref}, last_client_poll: now_ms()}}
      buffer ->
        broadcast_from!(state, client_ref, {:messages, Enum.reverse(buffer), ref})
        {:noreply, %{state | client_ref: nil, last_client_poll: now_ms(), buffer: []}}
    end
  end

  def handle_info(:shutdown_if_inactive, state) do
    if now_ms() - state.last_client_poll > state.window_ms do
      {:stop, {:shutdown, :inactive}, state}
    else
      schedule_inactive_shutdown(state.window_ms)
      {:noreply, state}
    end
  end

  def handle_info(message, state) do
    %{handler: {handler, handler_state}} = state

    case handler.handle_info(message, handler_state) do
      {:push, {_, reply}, handler_state} ->
        state = %{state | handler: {handler, handler_state}}
        publish_reply(state, reply)

      {:ok, handler_state} ->
        state = %{state | handler: {handler, handler_state}}
        {:noreply, state}

      {:stop, reason, handler_state} ->
        state = %{state | handler: {handler, handler_state}}
        {:stop, reason, state}
    end
  end

  def terminate(reason, state) do
    %{handler: {handler, handler_state}} = state
    handler.terminate(reason, handler_state)
    :ok
  end

  defp broadcast_from!(state, client_ref, msg) when is_binary(client_ref),
    do: PubSub.broadcast_from!(state.pubsub_server, self(), client_ref, msg)
  defp broadcast_from!(_state, client_ref, msg) when is_pid(client_ref),
    do: send(client_ref, msg)

  defp publish_reply(state, reply) do
    notify_client_now_available(state)
    {:noreply, update_in(state.buffer, &[reply | &1])}
  end

  defp notify_client_now_available(state) do
    case state.client_ref do
      {client_ref, ref} -> broadcast_from!(state, client_ref, {:now_available, ref})
      nil -> :ok
    end
  end

  defp now_ms, do: System.system_time(:milliseconds)

  defp schedule_inactive_shutdown(window_ms) do
    Process.send_after(self(), :shutdown_if_inactive, window_ms)
  end
end
