defmodule AshAiTest do
  use ExUnit.Case, async: true
  alias AshAi.ChatFaker
  alias LangChain.Chains.LLMChain
  alias LangChain.Message
  alias __MODULE__.{Music, Artist}

  defmodule Artist do
    use Ash.Resource, domain: Music, data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id, writable?: true)
      attribute(:name, :string, public?: true)
    end

    actions do
      default_accept([:*])
      defaults([:create, :read, :update, :destroy])

      action :say_hello, :string do
        argument(:name, :string, allow_nil?: false)

        run(fn input, _ ->
          {:ok, "Hello: #{input.arguments.name}"}
        end)
      end
    end
  end

  defmodule Music do
    use Ash.Domain, extensions: [AshAi]

    resources do
      resource(Artist)
    end

    tools do
      tool(:list_artists, Artist, :read, async: false)
      tool(:create_artist, Artist, :create, async: false)
      tool(:update_artist, Artist, :update, async: false)
      tool(:delete_artist, Artist, :destroy, async: false)
      tool(:say_hello, Artist, :say_hello, async: false)
    end
  end

  describe "setup_ash_ai" do
    setup do
      artist =
        Artist
        |> Ash.Changeset.for_create(:create, %{name: "Chet Baker"})
        |> Ash.create!()

      %{artist: artist}
    end

    test "with read action", %{artist: artist} do
      tool_call = tool_call("list_artists", %{"filter" => %{"name" => %{"eq" => artist.name}}})

      assert {:ok, new_chain} = chain() |> run_chain(tool_call)

      assert [fetched_artist] = new_chain.last_message.processed_content
      assert fetched_artist.id == artist.id
    end

    test "with create action" do
      tool_call = tool_call("create_artist", %{"input" => %{"name" => "Chat Faker"}})

      assert {:ok, new_chain} = chain() |> run_chain(tool_call)

      assert %Artist{name: "Chat Faker"} = new_chain.last_message.processed_content
    end

    test "with update action", %{artist: artist} do
      tool_call =
        tool_call("update_artist", %{"id" => artist.id, "input" => %{"name" => "Chat Faker"}})

      assert {:ok, new_chain} = chain() |> run_chain(tool_call)

      assert %Artist{name: "Chat Faker"} = new_chain.last_message.processed_content
    end

    test "with destroy action", %{artist: artist} do
      tool_call = tool_call("delete_artist", %{"id" => artist.id})

      assert {:ok, new_chain} = chain() |> run_chain(tool_call)

      assert %Artist{name: "Chet Baker"} = new_chain.last_message.processed_content
    end

    test "with action" do
      tool_call = tool_call("say_hello", %{"input" => %{"name" => "Chat Faker"}})

      assert {:ok, new_chain} = chain() |> run_chain(tool_call)

      assert "Hello: Chat Faker" = new_chain.last_message.processed_content
    end
  end

  defp tool_call(name, arguments) do
    %LangChain.Message.ToolCall{
      status: :complete,
      type: :function,
      call_id: "call_id",
      name: name,
      arguments: arguments,
      index: 0
    }
  end

  defp chain() do
    actions =
      AshAi.Info.tools(Music)
      |> Enum.group_by(& &1.resource, & &1.action)
      |> Map.to_list()

    %{llm: ChatFaker.new!(%{expect_fun: expect_fun()})}
    |> LLMChain.new!()
    |> AshAi.setup_ash_ai(actions: actions)
  end

  defp expect_fun() do
    fn _chat_model, messages, _tools ->
      Message.new_assistant(%{processed_content: last_processed_content(messages)})
    end
  end

  defp run_chain(chain, tool_call) do
    chain
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
