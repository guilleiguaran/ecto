defmodule Ecto.Adapters.Postgres.SQL do
  @moduledoc false

  # This module handles the generation of SQL code from queries and for create,
  # update and delete. All queries has to be normalized and validated for
  # correctness before given to this module.

  require Ecto.Query
  alias Ecto.Query.Query
  alias Ecto.Query.QueryExpr
  alias Ecto.Query.BuilderUtil

  binary_ops =
    [ ==: "=", !=: "!=", <=: "<=", >=: ">=", <:  "<", >:  ">",
      and: "AND", or: "OR",
      +:  "+", -:  "-", *:  "*", /:  "/" ]

  @binary_ops Dict.keys(binary_ops)

  Enum.map(binary_ops, fn { op, str } ->
    defp binop_to_binary(unquote(op)), do: unquote(str)
  end)

  # Generate SQL for a select statement
  def select(Query[] = query) do
    # Generate SQL for every query expression type and combine to one string
    select   = select(query.select, query.froms)
    from     = from(query.froms)
    where    = where(query.wheres, query.froms)
    order_by = order_by(query.order_bys, query.froms)
    limit    = if query.limit, do: limit(query.limit.expr)
    offset   = if query.offset, do: offset(query.offset.expr)

    [select, from, where, order_by, limit, offset]
      |> Enum.filter(fn x -> x != nil end)
      |> Enum.join("\n")
  end

  # Generate SQL for an insert statement
  def insert(entity) do
    module      = elem(entity, 0)
    table       = module.__ecto__(:table)
    fields      = module.__ecto__(:field_names)
    primary_key = module.__ecto__(:primary_key)

    [_|values] = tuple_to_list(entity)

    # Remove primary key from insert fields and values
    if primary_key do
      [_|insert_fields] = fields
      [_|values] = values
    else
      insert_fields = fields
    end

    "INSERT INTO #{table} (" <> Enum.join(insert_fields, ", ") <> ")\n" <>
    "VALUES (" <> Enum.map_join(values, ", ", literal(&1)) <> ")" <>
    if primary_key, do: "\nRETURNING #{primary_key}", else: ""
  end

  # Generate SQL for an update statement
  def update(entity) do
    module      = elem(entity, 0)
    table       = module.__ecto__(:table)
    fields      = module.__ecto__(:field_names)
    primary_key = module.__ecto__(:primary_key)

    # Remove primary key from fields and values
    [_|fields] = fields
    [_|[primary_key_value|values]] = tuple_to_list(entity)

    zipped = Enum.zip(fields, values)
    zipped_sql = Enum.map_join(zipped, ", ", fn({k, v}) ->
      "#{k} = #{literal(v)}"
    end)

    "UPDATE #{table} SET " <> zipped_sql <> "\n" <>
    "WHERE #{primary_key} = #{literal(primary_key_value)}"
  end

  # Generate SQL for a delete statement
  def delete(entity) do
    module            = elem(entity, 0)
    table             = module.__ecto__(:table)
    primary_key       = module.__ecto__(:primary_key)
    primary_key_value = elem(entity, 1)

    "DELETE FROM #{table} WHERE #{primary_key} = #{literal(primary_key_value)}"
  end

  defp select(QueryExpr[expr: expr, binding: binding], vars) do
    { _, clause } = expr
    vars = BuilderUtil.merge_binding_vars(binding, vars)
    "SELECT " <> select_clause(clause, vars)
  end

  defp from(froms) do
    binds = Enum.map_join(froms, ", ", fn({ var, entity }) ->
      table = entity.__ecto__(:table)
      "#{table} AS #{var}"
    end)

    "FROM " <> binds
  end

  defp where([], _vars), do: nil

  defp where(wheres, vars) do
    exprs = Enum.map_join(wheres, " AND ", fn(QueryExpr[expr: expr, binding: binding]) ->
      rebound_vars = BuilderUtil.merge_binding_vars(binding, vars)
      "(" <> expr(expr, rebound_vars) <> ")"
    end)

    "WHERE " <> exprs
  end

  defp order_by([], _vars), do: nil

  defp order_by(order_bys, vars) do
    exprs = Enum.map_join(order_bys, ", ", fn(QueryExpr[expr: expr, binding: binding]) ->
      rebound_vars = BuilderUtil.merge_binding_vars(binding, vars)
      Enum.map_join(expr, ", ", order_by_expr(&1, rebound_vars))
    end)

    "ORDER BY " <> exprs
  end

  defp order_by_expr({ dir, var, field }, vars) do
    { var, _ } = Keyword.fetch!(vars, var)
    str = "#{var}.#{field}"
    case dir do
      nil   -> str
      :asc  -> str <> " ASC"
      :desc -> str <> " DESC"
    end
  end

  defp limit(num), do: "LIMIT " <> integer_to_binary(num)
  defp offset(num), do: "OFFSET " <> integer_to_binary(num)

  defp expr({ expr, _, [] }, vars) do
    expr(expr, vars)
  end

  defp expr({ :., _, [{ var, _, context }, field] }, vars)
      when is_atom(var) and is_atom(context) and is_atom(field) do
    { var, _ } = Keyword.fetch!(vars, var)
    "#{var}.#{field}"
  end

  defp expr({ :!, _, [expr] }, vars) do
    "NOT (" <> expr(expr, vars) <> ")"
  end

  # Expression builders make sure that we only find undotted vars at the top level
  defp expr({ var, _, context }, vars) when is_atom(var) and is_atom(context) do
    { var, entity } = Keyword.fetch!(vars, var)
    fields = entity.__ecto__(:field_names)
    Enum.map_join(fields, ", ", fn(field) -> "#{var}.#{field}" end)
  end

  defp expr({ op, _, [expr] }, vars) when op in [:+, :-] do
    atom_to_binary(op) <> expr(expr, vars)
  end

  defp expr({ :==, _, [nil, right] }, vars) do
    "#{op_to_binary(right, vars)} IS NULL"
  end

  defp expr({ :==, _, [left, nil] }, vars) do
    "#{op_to_binary(left, vars)} IS NULL"
  end

  defp expr({ :!=, _, [nil, right] }, vars) do
    "#{op_to_binary(right, vars)} IS NOT NULL"
  end

  defp expr({ :!=, _, [left, nil] }, vars) do
    "#{op_to_binary(left, vars)} IS NOT NULL"
  end

  defp expr({ op, _, [left, right] }, vars) when op in @binary_ops do
    "#{op_to_binary(left, vars)} #{binop_to_binary(op)} #{op_to_binary(right, vars)}"
  end

  defp expr(literal, _vars), do: literal(literal)

  defp literal(nil), do: "NULL"

  defp literal(true), do: "TRUE"

  defp literal(false), do: "FALSE"

  defp literal(literal) when is_binary(literal) do
    "'#{escape_string(literal)}'"
  end

  defp literal(literal) when is_number(literal) do
    to_binary(literal)
  end

  # TODO: Make sure that Elixir's to_binary for numbers is compatible with PG
  # http://www.postgresql.org/docs/9.2/interactive/sql-syntax-lexical.html

  defp op_to_binary({ op, _, [_, _] } = expr, vars) when op in @binary_ops do
    "(" <> expr(expr, vars) <> ")"
  end

  defp op_to_binary(expr, vars) do
    expr(expr, vars)
  end

  # TODO: Records (Kernel.access)
  defp select_clause({ :{}, _, elems }, vars) do
    Enum.map_join(elems, ", ", select_clause(&1, vars))
  end

  defp select_clause({ x, y }, vars) do
    select_clause({ :{}, [], [x, y] }, vars)
  end

  defp select_clause(list, vars) when is_list(list) do
    Enum.map_join(list, ", ", select_clause(&1, vars))
  end

  defp select_clause(expr, vars) do
    expr(expr, vars)
  end

  defp escape_string(value) when is_binary(value) do
    value
      |> :binary.replace("\\", "\\\\", [:global])
      |> :binary.replace("'", "''", [:global])
  end
end
