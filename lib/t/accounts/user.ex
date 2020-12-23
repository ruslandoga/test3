defmodule T.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset
  import TWeb.Gettext

  # https://hexdocs.pm/pow/lock_users.html#content

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  schema "users" do
    field :phone_number, :string
    # field :confirmed_at, :naive_datetime
    field :blocked_at, :utc_datetime
    field :onboarded_at, :utc_datetime

    has_one :profile, __MODULE__.Profile

    timestamps()
  end

  @doc """
  A user changeset for registration.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:phone_number])
    |> validate_phone_number()
  end

  defp validate_phone_number(changeset) do
    changeset
    |> validate_required([:phone_number])
    |> validate_change(:phone_number, fn :phone_number, phone_number ->
      if T.Accounts.valid_number?(phone_number) do
        []
      else
        [phone_number: dgettext("errors", "is invalid")]
      end
    end)
    |> unsafe_validate_unique(:phone_number, T.Repo)
    |> unique_constraint(:phone_number)
  end
end