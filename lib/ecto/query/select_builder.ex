defmodule Ecto.Query.SelectBuilder do
  @moduledoc false

  alias Ecto.Query.BuilderUtil

  # Escapes a select query to `{ :single | :tuple | :list | { :entity, var },
  # escaped_query }` The first element in the pair specifies the transformation
  # the adapter should perform on the results from the data store.

  # Handle any top level tuples or lists
  def escape({ left, right }, vars) do
    { :tuple, [BuilderUtil.escape(left, vars), BuilderUtil.escape(right, vars)] }
  end

  def escape({ :{}, _, list }, vars) do
    { :tuple, Enum.map(list, BuilderUtil.escape(&1, vars)) }
  end

  def escape(list, vars) when is_list(list) do
    { :list, Enum.map(list, BuilderUtil.escape(&1, vars)) }
  end

  # var - where var is bound
  def escape({ var, _, context} = ast, vars) when is_atom(var) and is_atom(context) do
    if var in vars do
      { { :entity, var }, Macro.escape(ast) }
    else
      { :single, ast }
    end
  end

  def escape(other, vars) do
    { :single, BuilderUtil.escape(other, vars) }
  end
end
