defmodule Conformance.AuthController do
  use Phoenix.Controller
  use Conformance, :verified_routes

  require Logger

  alias Oidcc.Token

  plug Oidcc.Plug.AuthorizationCallback,
       [
         provider: Conformance.ConfigWorker,
         client_id: &Conformance.RegisterClient.client_id/0,
         client_secret: &Conformance.RegisterClient.client_secret/0,
         redirect_uri: &__MODULE__.redirect_url/0
       ]
       when action in [:callback]

  plug Oidcc.Plug.Authorize,
       [
         provider: Conformance.ConfigWorker,
         client_id: &Conformance.RegisterClient.client_id/0,
         client_secret: &Conformance.RegisterClient.client_secret/0,
         redirect_uri: &__MODULE__.redirect_url/0,
         scopes: ["openid", "profile"]
       ]
       when action in [:authorize]

  def authorize(conn, _params), do: conn

  def callback_form(conn, %{"code" => code}) do
    # Redirect neccesary since session does not include nonce
    # on cross origin post
    redirect(conn, to: ~p"/callback?code=#{code}")
  end

  def callback(
        %Plug.Conn{
          private: %{
            Oidcc.Plug.AuthorizationCallback => {:ok, {token, userinfo}}
          }
        } = conn,
        _params
      ) do
    Logger.info("Retrieved Token: #{inspect(token, pretty: true)}")
    Logger.info("Retrieved Userinfo: #{inspect(userinfo, pretty: true)}")

    conn =
      with {:ok, {refreshed_token, refreshed_userinfo}} <- maybe_refresh(token) do
        send_resp(
          conn,
          200,
          inspect(
            %{
              token: token,
              userinfo: userinfo,
              refreshed_token: refreshed_token,
              refreshed_userinfo: refreshed_userinfo
            },
            pretty: true
          )
        )
      else
        {:error, reason} -> error_response(conn, reason)
      end

    spawn(fn ->
      Process.sleep(2_000)

      Conformance.Screenshot.take()
      Process.send(Conformance.Runner, :stop, [])
    end)

    conn
  end

  def callback(
        %Plug.Conn{
          private: %{
            Oidcc.Plug.AuthorizationCallback => {:error, reason}
          }
        } = conn,
        _params
      ) do
    conn = error_response(conn, reason)

    spawn(fn ->
      Process.sleep(2_000)

      Conformance.Screenshot.take()
      Process.send(Conformance.Runner, :stop, [])
    end)

    conn
  end

  defp maybe_refresh(%Token{refresh: %Token.Refresh{token: _refresh_token}} = token) do
    with {:ok, token} <-
           Oidcc.refresh_token(
             token,
             Conformance.ConfigWorker,
             Conformance.RegisterClient.client_id(),
             Conformance.RegisterClient.client_secret()
           ),
         {:ok, userinfo} <-
           Oidcc.retrieve_userinfo(
             token,
             Conformance.ConfigWorker,
             Conformance.RegisterClient.client_id(),
             Conformance.RegisterClient.client_secret(),
             %{}
           ) do
      Logger.info("Retrieved Token: #{inspect(token, pretty: true)}")
      Logger.info("Retrieved Userinfo: #{inspect(userinfo, pretty: true)}")

      {:ok, {token, userinfo}}
    end
  end

  defp maybe_refresh(%Token{}), do: {:ok, {nil, nil}}

  defp error_response(conn, reason) do
    Logger.error("OIDC Error: #{inspect(reason, pretty: true)}")

    send_resp(conn, 400, inspect(reason, pretty: true))
  end

  def redirect_url, do: url(~p"/callback")
end
