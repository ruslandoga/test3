defmodule T.Media do
  def bucket do
    # TODO use mox in test env
    Application.fetch_env!(:ex_aws, :s3)[:bucket]
  end

  def presigned_url(method \\ :get, key) do
    {:ok, url} = ExAws.S3.presigned_url(ExAws.Config.new(:s3), method, bucket(), key)
    url
  end

  def s3_url do
    "https://#{bucket()}.s3.amazonaws.com"
  end

  def s3_url(s3_key) do
    Path.join(s3_url(), s3_key)
  end

  def imgproxy_url(key_or_url, opts \\ [])

  def imgproxy_url("http" <> _rest = url, opts) do
    # TODO vary by device, sharpen
    default_opts = [width: 1000, height: 1000, enlarge: "0", resize: "fit"]
    opts = Keyword.merge(default_opts, opts)
    Imgproxy.url(url, opts)
  end

  def imgproxy_url(s3_key, opts) do
    imgproxy_url(s3_url(s3_key), opts)
  end

  def clean_url(presigned_url) do
    if presigned_url, do: URI.to_string(%URI{URI.parse(presigned_url) | query: nil})
  end

  def file_exists?(key) do
    bucket()
    |> ExAws.S3.head_object(key)
    |> ExAws.request()
    |> case do
      {:ok, %{status_code: 200}} -> true
      {:error, {:http_error, 404, %{status_code: 404}}} -> false
    end
  end

  def presign_config do
    env = Application.get_all_env(:ex_aws)

    %{
      region: Application.fetch_env!(:ex_aws, :region),
      access_key_id: env[:access_key_id] || System.fetch_env!("AWS_ACCESS_KEY_ID"),
      secret_access_key: env[:secret_access_key] || System.fetch_env!("AWS_SECRET_ACCESS_KEY")
    }
  end

  # https://gist.github.com/chrismccord/37862f1f8b1f5148644b75d20d1cb073
  # Dependency-free S3 Form Upload using HTTP POST sigv4

  # https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-post-example.html

  @doc """
  Signs a form upload.

  The configuration is a map which must contain the following keys:

    * `:region` - The AWS region, such as "us-east-1"
    * `:access_key_id` - The AWS access key id
    * `:secret_access_key` - The AWS secret access key


  Returns a map of form fields to be used on the client via the JavaScript `FormData` API.

  ## Options

    * `:key` - The required key of the object to be uploaded.
    * `:max_file_size` - The required maximum allowed file size in bytes.
    * `:content_type` - The required MIME type of the file to be uploaded.
    * `:expires_in` - The required expiration time in milliseconds from now
      before the signed upload expires.

  ## Examples

      config = %{
        region: "us-east-1",
        access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
        secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")
      }

      {:ok, fields} =
        sign_form_upload(config, "my-bucket",
          key: "public/my-file-name",
          content_type: "image/png",
          max_file_size: 10_000,
          expires_in: :timer.hours(1)
        )

  """
  def sign_form_upload(config \\ presign_config(), bucket \\ bucket(), opts) do
    key = Keyword.fetch!(opts, :key)
    max_file_size = Keyword.fetch!(opts, :max_file_size)
    content_type = Keyword.fetch!(opts, :content_type)
    expires_in = Keyword.fetch!(opts, :expires_in)

    expires_at = DateTime.add(DateTime.utc_now(), expires_in, :millisecond)
    amz_date = amz_date(expires_at)
    credential = credential(config, expires_at)

    encoded_policy =
      Base.encode64("""
      {
        "expiration": "#{DateTime.to_iso8601(expires_at)}",
        "conditions": [
          {"bucket": "#{bucket}"},
          ["eq", "$key", "#{key}"],
          {"acl": "public-read"},
          ["eq", "$Content-Type", "#{content_type}"],
          ["content-length-range", 0, #{max_file_size}],
          {"x-amz-server-side-encryption": "AES256"},
          {"x-amz-credential": "#{credential}"},
          {"x-amz-algorithm": "AWS4-HMAC-SHA256"},
          {"x-amz-date": "#{amz_date}"}
        ]
      }
      """)

    fields = %{
      "key" => key,
      "acl" => "public-read",
      "content-type" => content_type,
      "x-amz-server-side-encryption" => "AES256",
      "x-amz-credential" => credential,
      "x-amz-algorithm" => "AWS4-HMAC-SHA256",
      "x-amz-date" => amz_date,
      "policy" => encoded_policy,
      "x-amz-signature" => signature(config, expires_at, encoded_policy)
    }

    {:ok, fields}
  end

  defp amz_date(time) do
    time
    |> NaiveDateTime.to_iso8601()
    |> String.split(".")
    |> List.first()
    |> String.replace("-", "")
    |> String.replace(":", "")
    |> Kernel.<>("Z")
  end

  defp credential(%{} = config, %DateTime{} = expires_at) do
    "#{config.access_key_id}/#{short_date(expires_at)}/#{config.region}/s3/aws4_request"
  end

  defp signature(config, %DateTime{} = expires_at, encoded_policy) do
    config
    |> signing_key(expires_at, "s3")
    |> sha256(encoded_policy)
    |> Base.encode16(case: :lower)
  end

  defp signing_key(%{} = config, %DateTime{} = expires_at, service) when service in ["s3"] do
    amz_date = short_date(expires_at)
    %{secret_access_key: secret, region: region} = config

    ("AWS4" <> secret)
    |> sha256(amz_date)
    |> sha256(region)
    |> sha256(service)
    |> sha256("aws4_request")
  end

  defp short_date(%DateTime{} = expires_at) do
    expires_at
    |> amz_date()
    |> String.slice(0..7)
  end

  defp sha256(secret, msg), do: :crypto.hmac(:sha256, secret, msg)

  def pic3d_job(s3_key) do
    %Oban.Job{
      args: %{s3_key: s3_key},
      queue: "pic3d",
      worker: "S.Pic3dJob"
    }
  end
end
