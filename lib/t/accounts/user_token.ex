defmodule T.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query

  @rand_size 32
  @session_validity_in_days 60

  @primary_key {:id, Ecto.Bigflake.UUID, autogenerate: true}
  @foreign_key_type Ecto.Bigflake.UUID
  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    belongs_to :user, T.Accounts.User

    timestamps(updated_at: false)
  end

  @doc false
  def raw_token(<<_::@rand_size-bytes>> = token), do: token

  def raw_token(<<_::43-bytes>> = token) do
    Base.url_decode64!(token, padding: false)
  end

  @doc false
  def encoded_token(<<_::43-bytes>> = token), do: token

  def encoded_token(<<_::@rand_size-bytes>> = token) do
    Base.url_encode64(token, padding: false)
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie or keychain. As they are signed, those
  tokens do not need to be hashed.
  """
  def build_token(user, context) when context in ["session", "mobile"] do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %T.Accounts.UserToken{token: token, context: context, user_id: user.id}}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token.
  """
  def verify_session_token_query(token) do
    query =
      from token in token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: user

    {:ok, query}
  end

  def verify_mobile_token_query(token) do
    query =
      from token in token_and_context_query(token, "mobile"),
        join: user in assoc(token, :user),
        # TODO expire after > 3 months of inactivity?
        select: user

    {:ok, query}
  end

  @doc """
  Returns the given token with the given context.
  """
  def token_and_context_query(token, context) do
    from T.Accounts.UserToken, where: [token: ^raw_token(token), context: ^context]
  end

  @doc """
  Gets all tokens for the given user for the given contexts.
  """
  def user_and_contexts_query(user, :all) do
    from t in T.Accounts.UserToken, where: t.user_id == ^user.id
  end

  def user_and_contexts_query(user, [_ | _] = contexts) do
    from t in T.Accounts.UserToken, where: t.user_id == ^user.id and t.context in ^contexts
  end
end
