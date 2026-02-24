# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Transformers.McpApps do
  @moduledoc false
  use Spark.Dsl.Transformer

  def after?(_), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    dsl_state
    |> Spark.Dsl.Transformer.get_entities([:tools])
    |> Enum.filter(& &1.ui)
    |> Enum.reduce({:ok, dsl_state}, fn tool, {:ok, dsl} ->
      updated_meta =
        (tool._meta || %{})
        |> Map.update("ui", %{"resourceUri" => tool.ui}, &Map.put(&1, "resourceUri", tool.ui))

      {:ok,
       Spark.Dsl.Transformer.replace_entity(
         dsl,
         [:tools],
         %{tool | _meta: updated_meta, ui: nil},
         &(&1.name == tool.name)
       )}
    end)
  end
end
