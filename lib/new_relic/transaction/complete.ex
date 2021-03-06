defmodule NewRelic.Transaction.Complete do
  @moduledoc false

  alias NewRelic.Util
  alias NewRelic.Harvest.Collector
  alias NewRelic.DistributedTrace
  alias NewRelic.Transaction

  def run(tx_attrs, pid) do
    {tx_segments, tx_attrs, tx_error, span_events, apdex} = gather_transaction_info(tx_attrs, pid)

    report_transaction_event(tx_attrs)
    report_transaction_trace(tx_attrs, tx_segments)
    report_transaction_error_event(tx_attrs, tx_error)
    report_transaction_metric(tx_attrs)
    report_aggregate(tx_attrs)
    report_caller_metric(tx_attrs)
    report_apdex_metric(apdex)
    report_span_events(span_events)
  end

  defp gather_transaction_info(tx_attrs, pid) do
    tx_attrs
    |> transform_name_attrs
    |> transform_time_attrs
    |> extract_transaction_info(pid)
  end

  defp transform_name_attrs(%{custom_name: name} = tx), do: Map.put(tx, :name, name)
  defp transform_name_attrs(%{framework_name: name} = tx), do: Map.put(tx, :name, name)
  defp transform_name_attrs(%{plug_name: name} = tx), do: Map.put(tx, :name, name)
  defp transform_name_attrs(%{other_transaction_name: name} = tx), do: Map.put(tx, :name, name)

  defp transform_time_attrs(
         %{start_time: start_time, end_time_mono: end_time_mono, start_time_mono: start_time_mono} =
           tx
       ) do
    start_time = System.convert_time_unit(start_time, :native, :millisecond)
    duration_us = System.convert_time_unit(end_time_mono - start_time_mono, :native, :microsecond)
    duration_ms = System.convert_time_unit(end_time_mono - start_time_mono, :native, :millisecond)

    tx
    |> Map.drop([:start_time_mono, :end_time_mono])
    |> Map.merge(%{
      start_time: start_time,
      end_time: start_time + duration_ms,
      duration_us: duration_us,
      duration_ms: duration_ms,
      duration_s: duration_ms / 1000
    })
  end

  defp extract_transaction_info(tx_attrs, pid) do
    {function_segments, tx_attrs} = Map.pop(tx_attrs, :trace_function_segments, [])
    {process_spawns, tx_attrs} = Map.pop(tx_attrs, :trace_process_spawns, [])
    {process_names, tx_attrs} = Map.pop(tx_attrs, :trace_process_names, [])
    {process_exits, tx_attrs} = Map.pop(tx_attrs, :trace_process_exits, [])
    {tx_error, tx_attrs} = Map.pop(tx_attrs, :transaction_error, nil)

    apdex = calculate_apdex(tx_attrs, tx_error)

    tx_attrs =
      tx_attrs
      |> Map.merge(NewRelic.Config.automatic_attributes())
      |> Map.put(:"nr.apdexPerfZone", Util.Apdex.label(apdex))

    function_segments =
      function_segments
      |> Enum.map(&transform_time_attrs/1)
      |> Enum.map(&transform_trace_time_attrs(&1, tx_attrs.start_time))
      |> Enum.map(&transform_trace_name_attrs/1)
      |> Enum.map(&struct(Transaction.Trace.Segment, &1))
      |> Enum.group_by(& &1.pid)
      |> Enum.into(%{}, &generate_process_segment_tree(&1))

    top_segment =
      tx_attrs
      |> Map.take([:name, :pid, :start_time, :end_time])
      |> List.wrap()
      |> Enum.map(&transform_trace_time_attrs(&1, tx_attrs.start_time))
      |> Enum.map(&transform_trace_name_attrs/1)
      |> Enum.map(&struct(Transaction.Trace.Segment, &1))
      |> List.first()
      |> Map.put(:id, pid)

    top_segment =
      process_spawns
      |> collect_process_segments(process_names, process_exits)
      |> Enum.map(&transform_trace_time_attrs(&1, tx_attrs.start_time))
      |> Enum.map(&transform_trace_name_attrs/1)
      |> Enum.map(&struct(Transaction.Trace.Segment, &1))
      |> Enum.sort_by(& &1.relative_start_time)
      |> Enum.map(&Map.put(&1, :children, function_segments[&1.pid] || []))
      |> generate_process_tree(root: top_segment)

    top_children = List.wrap(function_segments[inspect(pid)])
    top_segment = Map.update!(top_segment, :children, &(&1 ++ top_children))

    span_events = extract_span_events(tx_attrs, pid, process_spawns, process_names, process_exits)

    {[top_segment], tx_attrs, tx_error, span_events, apdex}
  end

  defp extract_span_events(tx_attrs, pid, spawns, names, exits) do
    spawned_process_span_events(tx_attrs, spawns, names, exits)
    |> add_root_process_span_event(tx_attrs, pid)
  end

  defp calculate_apdex(%{other_transaction_name: _}, _error) do
    :ignore
  end

  defp calculate_apdex(_tx_attrs, {:error, _error}) do
    :frustrating
  end

  defp calculate_apdex(%{duration_s: duration_s}, nil) do
    Util.Apdex.calculate(duration_s, apdex_t())
  end

  defp add_root_process_span_event(spans, %{sampled: true} = tx_attrs, pid) do
    [
      %NewRelic.Span.Event{
        trace_id: tx_attrs[:traceId],
        transaction_id: tx_attrs[:guid],
        sampled: true,
        priority: tx_attrs[:priority],
        category: "generic",
        name: "Transaction Root Process #{inspect(pid)}",
        guid: DistributedTrace.generate_guid(pid: pid),
        parent_id: tx_attrs[:parentSpanId],
        timestamp: tx_attrs[:start_time],
        duration: tx_attrs[:duration_s],
        entry_point: true
      }
      | spans
    ]
  end

  defp add_root_process_span_event(spans, _tx_attrs, _pid), do: spans

  defp spawned_process_span_events(tx_attrs, process_spawns, process_names, process_exits) do
    process_spawns
    |> collect_process_segments(process_names, process_exits)
    |> Enum.map(&transform_trace_name_attrs/1)
    |> Enum.map(fn proc ->
      %NewRelic.Span.Event{
        trace_id: tx_attrs[:traceId],
        transaction_id: tx_attrs[:guid],
        sampled: tx_attrs[:sampled],
        priority: tx_attrs[:priority],
        category: "generic",
        name: "Process #{proc.name || proc.pid}",
        guid: DistributedTrace.generate_guid(pid: proc.id),
        parent_id: DistributedTrace.generate_guid(pid: proc.parent_id),
        timestamp: proc[:start_time],
        duration: (proc[:end_time] - proc[:start_time]) / 1000
      }
    end)
  end

  defp collect_process_segments(spawns, names, exits) do
    for {pid, start_time, original} <- spawns,
        {^pid, name} <- names,
        {^pid, end_time} <- exits do
      %{
        pid: inspect(pid),
        id: pid,
        parent_id: original,
        name: name,
        start_time: start_time,
        end_time: end_time
      }
    end
  end

  defp transform_trace_time_attrs(
         %{start_time: start_time, end_time: end_time} = attrs,
         trace_start_time
       ) do
    attrs
    |> Map.merge(%{
      relative_start_time: start_time - trace_start_time,
      relative_end_time: end_time - trace_start_time
    })
  end

  defp transform_trace_name_attrs(
         %{
           primary_name: metric_name,
           secondary_name: class_name,
           attributes: attributes
         } = attrs
       ) do
    attrs
    |> Map.merge(%{
      class_name: class_name,
      method_name: nil,
      metric_name: metric_name |> String.replace("/", ""),
      attributes: attributes
    })
  end

  defp transform_trace_name_attrs(
         %{
           module: module,
           function: function,
           arity: arity,
           args: args
         } = attrs
       ) do
    attrs
    |> Map.merge(%{
      class_name: "#{function}/#{arity}",
      method_name: nil,
      metric_name: "#{inspect(module)}.#{function}",
      attributes: %{query: inspect(args, charlists: false)}
    })
  end

  defp transform_trace_name_attrs(%{pid: pid, name: name} = attrs) do
    attrs
    |> Map.merge(%{class_name: name || "Process", method_name: nil, metric_name: pid})
  end

  defp generate_process_tree(processes, root: root) do
    parent_map = Enum.group_by(processes, & &1.parent_id)
    generate_tree(root, parent_map)
  end

  defp generate_process_segment_tree({pid, segments}) do
    parent_map = Enum.group_by(segments, & &1.parent_id)
    %{children: children} = generate_tree(%{id: :root}, parent_map)
    {pid, children}
  end

  defp generate_tree(leaf, parent_map) when map_size(parent_map) == 0 do
    leaf
  end

  defp generate_tree(parent, parent_map) do
    {children, parent_map} = Map.pop(parent_map, parent.id, [])

    children =
      children
      |> Enum.sort_by(& &1.relative_start_time)
      |> Enum.map(&generate_tree(&1, parent_map))

    Map.update(parent, :children, children, &(&1 ++ children))
  end

  defp report_caller_metric(
         %{
           "parent.type": parent_type,
           "parent.account": parent_account_id,
           "parent.app": parent_app_id,
           "parent.transportType": transport_type
         } = tx_attrs
       ) do
    NewRelic.report_metric(
      {:caller, parent_type, parent_account_id, parent_app_id, transport_type},
      duration_s: tx_attrs.duration_s
    )
  end

  defp report_caller_metric(tx_attrs) do
    NewRelic.report_metric(
      {:caller, "Unknown", "Unknown", "Unknown", "Unknown"},
      duration_s: tx_attrs.duration_s
    )
  end

  defp report_span_events(span_events) do
    Enum.each(span_events, &Collector.SpanEvent.Harvester.report_span_event/1)
  end

  defp report_transaction_event(%{transaction_type: :web} = tx_attrs) do
    Collector.TransactionEvent.Harvester.report_event(%Transaction.Event{
      timestamp: tx_attrs.start_time,
      duration: tx_attrs.duration_s,
      name: Util.metric_join(["WebTransaction", tx_attrs.name]),
      user_attributes:
        Map.merge(tx_attrs, %{
          request_url: "#{tx_attrs.host}#{tx_attrs.path}"
        })
    })
  end

  defp report_transaction_event(tx_attrs) do
    Collector.TransactionEvent.Harvester.report_event(%Transaction.Event{
      timestamp: tx_attrs.start_time,
      duration: tx_attrs.duration_s,
      name: Util.metric_join(["OtherTransaction", tx_attrs.name]),
      user_attributes: tx_attrs
    })
  end

  defp report_transaction_trace(%{other_transaction_name: _} = tx_attrs, tx_segments) do
    Collector.TransactionTrace.Harvester.report_trace(%Transaction.Trace{
      start_time: tx_attrs.start_time,
      metric_name: Util.metric_join(["OtherTransaction", tx_attrs.name]),
      request_url: "/Unknown",
      attributes: %{agentAttributes: tx_attrs},
      segments: tx_segments,
      duration: tx_attrs.duration_ms
    })
  end

  defp report_transaction_trace(tx_attrs, tx_segments) do
    Collector.TransactionTrace.Harvester.report_trace(%Transaction.Trace{
      start_time: tx_attrs.start_time,
      metric_name: Util.metric_join(["WebTransaction", tx_attrs.name]),
      request_url: "#{tx_attrs.host}#{tx_attrs.path}",
      attributes: %{agentAttributes: tx_attrs},
      segments: tx_segments,
      duration: tx_attrs.duration_ms
    })
  end

  defp report_transaction_error_event(_tx_attrs, nil), do: :ignore

  defp report_transaction_error_event(tx_attrs, {:error, error}) do
    attributes = Map.drop(tx_attrs, [:error, :error_kind, :error_reason, :error_stack])
    expected = parse_error_expected(error.reason)

    {exception_type, exception_reason, exception_stacktrace} =
      Util.Error.normalize(error.reason, error.stack)

    report_error_trace(
      tx_attrs,
      exception_type,
      exception_reason,
      expected,
      exception_stacktrace,
      attributes,
      error
    )

    report_error_event(
      tx_attrs,
      exception_type,
      exception_reason,
      expected,
      exception_stacktrace,
      attributes,
      error
    )

    unless expected do
      NewRelic.report_metric({:supportability, :error_event}, error_count: 1)
      NewRelic.report_metric(:error, error_count: 1)
    end
  end

  defp report_error_trace(
         %{other_transaction_name: _} = tx_attrs,
         exception_type,
         exception_reason,
         expected,
         exception_stacktrace,
         attributes,
         error
       ) do
    Collector.ErrorTrace.Harvester.report_error(%NewRelic.Error.Trace{
      timestamp: tx_attrs.start_time / 1_000,
      error_type: inspect(exception_type),
      message: exception_reason,
      expected: expected,
      stack_trace: exception_stacktrace,
      transaction_name: Util.metric_join(["OtherTransaction", tx_attrs.name]),
      agent_attributes: %{},
      user_attributes: Map.merge(attributes, %{process: error[:process]})
    })
  end

  defp report_error_trace(
         tx_attrs,
         exception_type,
         exception_reason,
         expected,
         exception_stacktrace,
         attributes,
         error
       ) do
    Collector.ErrorTrace.Harvester.report_error(%NewRelic.Error.Trace{
      timestamp: tx_attrs.start_time / 1_000,
      error_type: inspect(exception_type),
      message: exception_reason,
      expected: expected,
      stack_trace: exception_stacktrace,
      transaction_name: Util.metric_join(["WebTransaction", tx_attrs.name]),
      agent_attributes: %{
        request_uri: "#{tx_attrs.host}#{tx_attrs.path}"
      },
      user_attributes: Map.merge(attributes, %{process: error[:process]})
    })
  end

  defp report_error_event(
         %{other_transaction_name: _} = tx_attrs,
         exception_type,
         exception_reason,
         expected,
         exception_stacktrace,
         attributes,
         error
       ) do
    Collector.TransactionErrorEvent.Harvester.report_error(%NewRelic.Error.Event{
      timestamp: tx_attrs.start_time / 1_000,
      error_class: inspect(exception_type),
      error_message: exception_reason,
      expected: expected,
      transaction_name: Util.metric_join(["OtherTransaction", tx_attrs.name]),
      agent_attributes: %{},
      user_attributes:
        Map.merge(attributes, %{
          process: error[:process],
          stacktrace: Enum.join(exception_stacktrace, "\n")
        })
    })
  end

  defp report_error_event(
         tx_attrs,
         exception_type,
         exception_reason,
         expected,
         exception_stacktrace,
         attributes,
         error
       ) do
    Collector.TransactionErrorEvent.Harvester.report_error(%NewRelic.Error.Event{
      timestamp: tx_attrs.start_time / 1_000,
      error_class: inspect(exception_type),
      error_message: exception_reason,
      expected: expected,
      transaction_name: Util.metric_join(["WebTransaction", tx_attrs.name]),
      agent_attributes: %{
        http_response_code: tx_attrs.status,
        request_method: tx_attrs.request_method
      },
      user_attributes:
        Map.merge(attributes, %{
          process: error[:process],
          stacktrace: Enum.join(exception_stacktrace, "\n")
        })
    })
  end

  defp report_aggregate(%{other_transaction_name: _} = tx) do
    NewRelic.report_aggregate(%{type: :OtherTransaction, name: tx[:name]}, %{
      duration_us: tx.duration_us,
      duration_ms: tx.duration_ms,
      call_count: 1
    })
  end

  defp report_aggregate(tx) do
    NewRelic.report_aggregate(%{type: :Transaction, name: tx[:name]}, %{
      duration_us: tx.duration_us,
      duration_ms: tx.duration_ms,
      call_count: 1
    })
  end

  def report_transaction_metric(%{other_transaction_name: _} = tx) do
    NewRelic.report_metric({:other_transaction, tx.name}, duration_s: tx.duration_s)
  end

  def report_transaction_metric(tx) do
    NewRelic.report_metric({:transaction, tx.name}, duration_s: tx.duration_s)
  end

  def report_apdex_metric(:ignore), do: :ignore

  def report_apdex_metric(apdex) do
    NewRelic.report_metric(:apdex, apdex: apdex, threshold: apdex_t())
  end

  def apdex_t, do: Collector.AgentRun.lookup(:apdex_t)

  defp parse_error_expected(%{expected: true}), do: true
  defp parse_error_expected(_), do: false
end
