defmodule AshAi.OpenApiTest do
  use ExUnit.Case, async: true
  alias AshAi.ChatFaker

  alias __MODULE__.{Music, Artist, Album}

  defmodule Bio do
    use Ash.Resource, data_layer: :embedded

    attributes do
      attribute :birth, :date, allow_nil?: false, public?: true
    end
  end

  defmodule Artist do
    use Ash.Resource,
      domain: Music,
      data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    attributes do
      uuid_v7_primary_key(:id, writable?: true)
      attribute(:name, :string, public?: true)
      attribute(:bio, Bio, allow_nil?: false, public?: true)
    end

    actions do
      default_accept([:*])
      defaults([:create, :read, :update, :destroy])

      action :say_hello, :string do
        description("Say hello")
        argument(:name, :string, allow_nil?: false)

        run(fn input, _ ->
          {:ok, "Hello, #{input.arguments.name}!"}
        end)
      end
    end

    relationships do
      has_many(:albums, Album)
    end

    aggregates do
      count(:albums_count, :albums, public?: true, sortable?: false)

      sum(:albums_copies_sold, :albums, :copies_sold,
        default: 0,
        public?: true,
        filterable?: false
      )
    end
  end

  defmodule Album do
    use Ash.Resource,
      domain: Music,
      data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id, writable?: true)
      attribute(:title, :string)
      attribute(:copies_sold, :integer)
    end

    relationships do
      belongs_to(:artist, Artist)
    end

    actions do
      default_accept([:*])
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule Music do
    use Ash.Domain,
      extensions: [AshAi]

    resources do
      resource(Artist)
      resource(Album)
    end
  end

  defmodule Sentiment do
    use Ash.Resource, data_layer: :embedded

    attributes do
      attribute :sentiment, :string, public?: true
      attribute :confidence, :float, public?: true
      attribute :keywords, {:array, :string}, public?: true
    end

    actions do
      default_accept([:*])
      defaults([:create, :read])
    end
  end

  defmodule Summary do
    use Ash.Resource, data_layer: :embedded

    attributes do
      attribute :summary, :string, public?: true
      attribute :word_count, :integer, public?: true
      attribute :key_points, {:array, :string}, public?: true
    end

    actions do
      default_accept([:*])
      defaults([:create, :read])
    end
  end

  defmodule TestResource do
    use Ash.Resource,
      domain: TestDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshAi]

    ets do
      private?(true)
    end

    attributes do
      uuid_v7_primary_key(:id, writable?: true)
      attribute(:name, :string, public?: true, description: "The name of the test resource")
    end

    actions do
      default_accept([:*])
      defaults([:create, :read, :update, :destroy])

      action :analyze_sentiment, Sentiment do
        description("Analyze the sentiment of a given text")
        argument(:text, :string, allow_nil?: false)

        run prompt(
              fn _input, _context ->
                ChatFaker.new!(%{
                  expect_fun: fn _model, _messages, tools ->
                    completion_tool = Enum.find(tools, &(&1.name == "complete_request"))

                    tool_call = %LangChain.Message.ToolCall{
                      status: :complete,
                      type: :function,
                      call_id: "call_123",
                      name: "complete_request",
                      arguments: %{
                        "result" => %{
                          "sentiment" => "positive",
                          "confidence" => 0.92,
                          "keywords" => ["excellent", "wonderful", "fantastic"]
                        }
                      },
                      index: 0
                    }

                    {:ok,
                     LangChain.Message.new_assistant!(%{
                       status: :complete,
                       tool_calls: [tool_call]
                     })}
                  end
                })
              end,
              adapter: {AshAi.Actions.Prompt.Adapter.CompletionTool, [max_runs: 10]}
            )
      end

      action :generate_summary, Summary do
        description("Generate a summary of a document")
        argument(:content, :string, allow_nil?: false)
        argument(:max_words, :integer, allow_nil?: true)

        run prompt(
              fn _input, _context ->
                ChatFaker.new!(%{
                  expect_fun: fn _model, _messages, tools ->
                    completion_tool = Enum.find(tools, &(&1.name == "complete_request"))

                    tool_call = %LangChain.Message.ToolCall{
                      status: :complete,
                      type: :function,
                      call_id: "call_456",
                      name: "complete_request",
                      arguments: %{
                        "result" => %{
                          "summary" => "A well-written document about machine learning concepts.",
                          "word_count" => 58,
                          "key_points" => ["AI fundamentals", "Neural networks", "Deep learning"]
                        }
                      },
                      index: 0
                    }

                    {:ok,
                     LangChain.Message.new_assistant!(%{
                       status: :complete,
                       tool_calls: [tool_call]
                     })}
                  end
                })
              end,
              adapter: {AshAi.Actions.Prompt.Adapter.CompletionTool, [max_runs: 5]}
            )
      end
    end
  end

  defmodule TestDomain do
    use Ash.Domain,
      extensions: [AshAi],
      validate_config_inclusion?: false

    resources do
      resource TestResource
    end
  end

  describe "AshJsonApi.OpenApi vendoring regression tests" do
    setup do
      resources =
        [TestResource, Artist, Album]
        |> Enum.map(fn resource ->
          actions = Ash.Resource.Info.actions(resource)

          {resource, actions}
        end)

      {:ok, resources: resources}
    end

    test "for parameter_schema input properties", %{resources: resources} do
      for {resource, actions} <- resources do
        for action <- actions do
          vendored_schema =
            get_parameter_schema_properties(
              action,
              resource,
              &AshAi.OpenApi.resource_write_attribute_type/4
            )
            |> JSON.encode!()
            |> JSON.decode!()

          old_schema =
            get_parameter_schema_properties(
              action,
              resource,
              &AshJsonApi.OpenApi.resource_write_attribute_type/4
            )
            |> OpenApiSpex.OpenApi.to_map()

          assert vendored_schema == old_schema
        end
      end
    end

    test "for action specific properties", %{resources: resources} do
      for {resource, actions} <- resources do
        for action <- actions do
          vendored_schema =
            get_action_specific_properties(action, resource, AshAi.OpenApi)
            |> JSON.encode!()
            |> JSON.decode!()

          old_schema =
            get_action_specific_properties(
              action,
              resource,
              AshJsonApi.OpenApi
            )
            |> OpenApiSpex.OpenApi.to_map()

          assert vendored_schema == old_schema
        end
      end
    end
  end

  defp get_action_specific_properties(%{type: :read}, resource, module) do
    Ash.Resource.Info.fields(resource, [:attributes, :aggregates, :calculations])
    |> Enum.filter(&(&1.public? && &1.filterable?))
    |> Map.new(fn field ->
      value = apply(module, :raw_filter_type, [field, resource])

      {field.name, value}
    end)
  end

  defp get_action_specific_properties(%{type: type}, resource, module)
       when type in [:update, :destroy] do
    Map.new(Ash.Resource.Info.primary_key(resource), fn key ->
      attribute = Ash.Resource.Info.attribute(resource, key)
      value = apply(module, :resource_write_attribute_type, [attribute, resource, key])

      {key, value}
    end)
  end

  defp get_action_specific_properties(_action, _resource, _module) do
    %{}
  end

  defp get_parameter_schema_properties(action, resource, fun) do
    attributes =
      if action.type in [:action, :read] do
        %{}
      else
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.filter(&(&1.name in action.accept && &1.writable?))
        |> Map.new(fn attribute ->
          value =
            fun.(
              attribute,
              resource,
              action.type,
              :json
            )

          {attribute.name, value}
        end)
      end

    action.arguments
    |> Enum.filter(& &1.public?)
    |> Enum.reduce(attributes, fn argument, attributes ->
      value =
        fun.(argument, resource, :create, :json)

      Map.put(
        attributes,
        argument.name,
        value
      )
    end)
  end
end
