# Copyright 2026, Phillip Heller
#
# This file is part of Prodigy Reloaded.
#
# Prodigy Reloaded is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# Prodigy Reloaded is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with Prodigy Reloaded. If not,
# see <https://www.gnu.org/licenses/>.

defmodule Prodigy.Portal.Components.AuthCard do
  @moduledoc """
  Centred white card shell used by the auth-adjacent surfaces:
  `/users/login`, `/users/login/:token`, and the General pane of
  `/users/settings`. One source of truth for the column breakpoints
  means widening or narrowing those pages is a one-file change.

  Column sizing is tuned so the card doesn't drown in whitespace
  on desktop while still centring comfortably on xxl monitors -
  `col-xl-5` lands around 550px on a 1920px viewport.
  """
  use Phoenix.Component

  @doc """
  Wrap the block in a Bootstrap row/col/card shell. The card body
  background is forced to white+dark-text so the auth surfaces stay
  readable regardless of the site's dark navbar theming.

  Pass `title` and/or `subtitle` as slots or attrs for the built-in
  centred header block; pass your own header markup inside the block
  and omit both for full control.
  """
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def auth_card(assigns) do
    ~H"""
    <div class={["row justify-content-center", @class]}>
      <div class="col-md-8 col-lg-7 col-xl-5">
        <.auth_panel title={@title} subtitle={@subtitle} class="my-4">
          {render_slot(@inner_block)}
        </.auth_panel>
      </div>
    </div>
    """
  end

  @doc """
  The card-body half of `auth_card/1` without the row/col centring.
  Use inside an already-constrained column - the settings sidebar
  pane, a modal, etc.
  """
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def auth_panel(assigns) do
    ~H"""
    <div class={["card p-4", @class]} style="background-color: #fff; color: #212529;">
      <div :if={@title || @subtitle} class="mb-3">
        <h2 :if={@title} class="h5 mb-1">{@title}</h2>
        <p :if={@subtitle} class="text-muted small mb-0">{@subtitle}</p>
      </div>

      {render_slot(@inner_block)}
    </div>
    """
  end
end
