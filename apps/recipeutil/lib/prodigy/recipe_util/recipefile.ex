defmodule RecipeUtil.File do

  require Ecto.Query
  import Ecto.Changeset

  alias Prodigy.Core.Data.{Object, Repo}

  @subst_map  %{
    "Body" =>
    << 0xA1, 0xC8, 0xC0, 0xC0, 0xD2, 0xA3, 0xC4, 0xC0,
   0xD2, 0xC0, 0xBE, 0xC0, 0xC8, 0xB3, 0xC2, 0xC6,
   0xC2, 0xDE, 0xF8, 0xF1, 0xA2, 0xF0, 0xC0, 0xC0,
   0xC1, 0xEA, 0xB8, 0xC0, 0xC0, 0xD8, 0xDB, 0xF9,
   0xE8, 0xA4, 0xC2, 0xC4, 0xDF, 0xBE, 0xD0, 0x0F >> <>
    "This is line 1 that has been changed" <> << 0x0D, 0x0A, 0x20 >> <>
    "This is line 2" <> << 0x0D, 0x0A, 0x20 >> <>
    "This is a longer line 3",
    "HL" =>
    "This is a headline",
    "NextHL" =>
    "Go to next page"
  }

  @subst_map2  %{
    "Body" =>
    "This is line 1 that has been changed" <> << 0x0D, 0x0A, 0x20 >> <>
    "This is line 2" <> << 0x0D, 0x0A, 0x20 >> <>
    "This is a longer line 3",
    "HL" =>
    "This is a headline",
    "NextHL" =>
    "Go to next page"
  }

  def run(%{:page_setup => true} = args) do
    source = Map.get(args, :source)
    dest = Map.get(args, :dest)

    with {:ok, data} <- File.read(source) do
      data_with_page_info = NewsHeadlines.page_setup(data, 1, 2)
      if (dest) do
        File.write!(dest, data_with_page_info)
      else
        IO.inspect(data_with_page_info)
      end
    end
  end

  def run(%{:news_setup => true} = args) do
    source = Map.get(args, :source)
    # dest = Map.get(args, :dest)
    dest = "NH00A000B  "

    recipe_object =
      if String.printable?(source) do
        Object
        |> Ecto.Query.where([o], o.name == ^source)
        |> Ecto.Query.where([o], o.type == 200)
        |> Ecto.Query.select([o], [o.name, o.type, o.contents])
        |> Repo.one()
      else
        nil
      end

    if recipe_object != nil do
      # get file contents we want
      [_name, _type, contents] = recipe_object
      #make the file name we'll write to
      {base, extension} = String.split_at(source, 8)
      filename = "#{base}.#{extension}"


      # future magic here, make a news headline map
      #
      # Turn into a recipe struct with new headline info in it
      {:ok, recipe, _rest} = RecipeType.parse(contents, @subst_map)
      # new recipe data
      recipe_bytes = RecipeType.generate(recipe)

      # write to file so we can run cook on it
      cook_location = Application.fetch_env!(:recipe, :cook_location)
      rf_location = Path.join([cook_location, filename])
      File.write!(rf_location, recipe_bytes)

      # run cook on the file
      emu2_command = Path.join([cook_location, "emu2"])
      cook_command = Path.join([cook_location, "COOK.EXE"])
      # run_cook_command = "EMU2_DRIVE_C=#{cook_location} #{emu2_command} COOK.EXE /INH00A000.BDY /R6 #{filename}"
      System.cmd(emu2_command, [cook_command, "/INH00A000.BDY", "/R6", filename], env: [{"EMU2_DRIVE_C", cook_location}])

      # read the resulting files back in
      body_filename = Path.join(cook_location, "nh00a000.bdy")
      body_contents =
        File.read!(body_filename)
        |> NewsHeadlines.page_setup(1, 2)

      # Read the record from the database
      body_object =
        if String.printable?(dest) do
          Object
          |> Ecto.Query.where([o], o.name == ^dest)
          |> Ecto.Query.where([o], o.sequence == 1)
          |> Repo.one()
        else
          nil
        end

      IO.inspect(body_contents)
      if body_object != nil do
        IO.puts("Doing an update")
        Ecto.Changeset.change(body_object, %{contents: body_contents})
        |> Repo.update()
      else
        IO.puts("Doing an insert")
        Repo.insert(%Object{name: dest, sequence: 3, type: 8, version: 1,
                            contents: body_contents})
      end
    end
  end

  def run(%{} = args) do
    source = Map.get(args, :source)
    dest = Map.get(args, :dest)

    with {:ok, data} <- File.read(source) do
      {:ok, recipe, _rest} = RecipeType.parse(data, @subst_map)
      # IO.inspect(recipe_type)
      recipe_bytes = RecipeType.generate(recipe)
      if (dest) do
        File.write!(dest, recipe_bytes)
      else
        IO.inspect(recipe)
      end
    end
  end
end
