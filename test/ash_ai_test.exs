defmodule AshAiTest do
  use ExUnit.Case, async: true
  alias AshAi.ChatFaker
  alias LangChain.Chains.LLMChain
  alias LangChain.Message
  alias __MODULE__.{Blogs, Author}

  defmodule Author do
    use Ash.Resource, domain: Blogs, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id, writable?: true)
      attribute(:name, :string, public?: true)
    end

    actions do
      default_accept([:*])
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule Blogs do
    use Ash.Domain, extensions: [AshAi]

    resources do
      resource(Author)
    end

    tools do
      tool(:create_author, Author, :create)
    end
  end

  describe "setup_ash_ai" do
    test "with create action" do
      expect_fun = fn _chat_model, messages, _tools ->
        Message.new_assistant(%{processed_content: last_processed_content(messages)})
      end

      tool_call = %LangChain.Message.ToolCall{
        status: :complete,
        type: :function,
        call_id: "call_id",
        name: "create_author",
        arguments: %{
          "input" => %{
            "name" => "Chet Baker"
          }
        },
        index: 0
      }

      assert {:ok, new_chain} = run_chain(expect_fun, tool_call)

      assert %Author{name: "Chet Baker"} = new_chain.last_message.processed_content
    end
  end

  defp run_chain(expect_fun, tool_call) do
    actions =
      AshAi.Info.tools(Blogs)
      |> Enum.group_by(& &1.resource, & &1.action)
      |> Map.to_list()

    %{llm: ChatFaker.new!(%{expect_fun: expect_fun})}
    |> LLMChain.new!()
    |> AshAi.setup_ash_ai(actions: actions)
    |> LLMChain.add_message(Message.new_assistant!(%{status: :complete, tool_calls: [tool_call]}))
    |> LLMChain.run(mode: :while_needs_response)
  end

  defp last_processed_content(messages) do
    messages
    |> List.last()
    |> Map.get(:tool_results)
    |> List.first()
    |> Map.get(:processed_content)
  end
end
