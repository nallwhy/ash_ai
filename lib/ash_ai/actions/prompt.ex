defmodule AshAi.Actions.Prompt do
  use Ash.Resource.Actions.Implementation

  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  def run(input, opts, context) do
    llm =
      case opts[:llm] do
        function when is_function(function) ->
          function.input(input, context)

        llm ->
          llm
      end

    if !Map.has_key?(llm, :json_schema) do
      raise "Only LLMs that have the `json_schema` can currently be used to run actions"
    end

    json_schema =
      if input.action.returns do
        schema =
          AshJsonApi.OpenApi.resource_write_attribute_type(
            %{name: :result, type: input.action.returns, constraints: input.action.constraints},
            nil,
            :create
          )

        if input.action.allow_nil? do
          %{"anyOf" => [%{"type" => "null"}, schema]}
        else
          schema
        end
      else
        %{"type" => "null"}
      end
      |> Jason.encode!()
      |> Jason.decode!()
      |> then(fn schema ->
        %{
          "strict" => true,
          "schema" => %{
            "type" => "object",
            "properties" => %{"result" => schema},
            "required" => ["result"],
            "additionalProperties" => false
          },
          "name" => "result"
        }
      end)

    llm =
      Map.merge(llm, %{json_schema: json_schema, json_response: true})

    tools =
      case opts[:tools] do
        nil ->
          []

        true ->
          otp_app =
            Spark.otp_app(input.domain) ||
              Spark.otp_app(input.resource) ||
              raise "otp_app must be configured on the domain or the resource to get access to all tools"

          AshAi.functions(
            otp_app: otp_app,
            exclude_actions: [{input.resource, input.action.name}],
            actor: context.actor,
            tenant: context.tenant
          )

        tools ->
          otp_app =
            Spark.otp_app(input.domain) ||
              Spark.otp_app(input.resource) ||
              raise "otp_app must be configured on the domain or the resource to get access to all tools"

          AshAi.functions(
            tools: List.wrap(tools),
            otp_app: otp_app,
            exclude_actions: [{input.resource, input.action.name}],
            actor: context.actor,
            tenant: context.tenant
          )
      end

    prompt =
      case Keyword.fetch(opts, :prompt) do
        {:ok, value} ->
          EEx.eval_string(value, input: input, context: context)

        _ ->
          """
          You are responsible for performing the `#{input.action.name}` action.

          #{description(input)}
          #{inputs(input)}
          """
      end

    messages = [
      Message.new_system!(prompt),
      Message.new_user!("Perform the action.")
    ]

    %{
      llm: llm,
      verbose: opts[:verbose] || false,
      custom_context: Map.new(Ash.Context.to_opts(context))
    }
    |> LLMChain.new!()
    |> LLMChain.add_messages(messages)
    |> LLMChain.add_tools(tools)
    |> LLMChain.run(mode: :while_needs_response)
    |> case do
      {:ok,
       %LangChain.Chains.LLMChain{
         last_message: %{content: content}
       }}
      when is_binary(content) ->
        if input.action.returns do
          with {:ok, value} <-
                 Ash.Type.cast_input(
                   input.action.returns,
                   Jason.decode!(content)["result"],
                   input.action.constraints
                 ),
               {:ok, value} <-
                 Ash.Type.apply_constraints(input.action.returns, value, input.action.constraints) do
            {:ok, value}
          else
            _error ->
              {:error, "Invalid LLM response"}
          end
        else
          :ok
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp description(input) do
    if input.action.description do
      "# Description\n\n#{input.action.description}"
    else
      ""
    end
  end

  defp inputs(%{action: %{arguments: []}}) do
    ""
  end

  defp inputs(%{action: %{arguments: arguments}} = input) do
    arguments
    |> Enum.reduce(%{}, fn argument, acc ->
      with {:ok, value} <- Ash.ActionInput.fetch_argument(input, argument.name),
           {:ok, value} <- Ash.Type.dump_to_embedded(argument.type, value, argument.constraints) do
        """
        ## #{argument.name}
        """
        |> then(fn text ->
          if argument.description do
            text <> "\n### Description:\n\n#{argument.description}\n"
          else
            text
          end
        end)
        |> Kernel.<>("### Value:\n\n#{Jason.encode!(value)}")
      else
        _ ->
          acc
      end
    end)
  end
end
