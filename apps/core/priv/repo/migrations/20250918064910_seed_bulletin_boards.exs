# Copyright 2022-2025, Phillip Heller
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

defmodule Prodigy.Core.Data.Repo.Migrations.SeedBulletinBoards do
  use Ecto.Migration

  def up do
    # Insert clubs
    clubs_data = [
      %{handle: "ZC0", name: "Arts Club"},
      %{handle: "GCC", name: "Computer Club"},
      %{handle: "ZC1", name: "Food and Wine"},
      %{handle: "ZC2", name: "Homelife"},
      %{handle: "GN0", name: "Money Talk"},
      %{handle: "GQ0", name: "The Club"},
      %{handle: "ZC3", name: "Travel Club"},
      %{handle: "ZC4", name: "Closeup Board"}
    ]

    # Insert clubs and get their IDs
    for club <- clubs_data do
      execute """
      INSERT INTO club (handle, name, inserted_at, updated_at)
      VALUES ('#{club.handle}', '#{club.name}', NOW(), NOW())
      ON CONFLICT (handle) DO NOTHING;
      """
    end

    # Insert topics for each club
    topics_by_club = %{
      "ZC0" => [
        "Rock/Pop",
        "Jazz/Clasical",
        "Live Music",
        "Other Music",
        "TV Soap Operas",
        "Visual Arts",
        "Science Fiction",
        "Movies",
        "Music",
        "Writing",
        "TV",
        "Books",
        "Theater"
      ],
      "GCC" => [
        "Programming",
        "PC Industry",
        "Financial Software",
        "Adventure Games",
        "Video Games",
        "Other Games",
        "Mac Software",
        "Word Proc/Desk Pub",
        "Spread Sheets/Databases",
        "Utilities",
        "Beginners",
        "Operating Systems",
        "Communications",
        "Other PC Topics",
        "Hardware:Systems",
        "Hardware:Peripherals",
        "Software",
        "Mac Hardware",
        "User Interfaces",
        "MIDI/Computer Audio"
      ],
      "ZC1" => [
        "Food Forum",
        "Asian Cuisine",
        "Busy Cook",
        "Healthy Eating",
        "Desserts & Sweets",
        "Talk to Guest Chef",
        "Bytable Recipes",
        "Wines and Spirits",
        "Eating Out",
        "Holiday",
        "Beers & Brewing"
      ],
      "ZC2" => [
        "House",
        "Garden",
        "Garage",
        "Fashion",
        "Parenting",
        "Pets",
        "Crafts",
        "Hobbies",
        "Genealogy",
        "Photography",
        "Amateur Radio",
        "Outdoor Hobbies",
        "Audio/Visual Hobies",
        "Collecting"
      ],
      "GN0" => [
        "Investments",
        "Real Estate",
        "Financial Planning",
        "Insurance",
        "Taxes",
        "Your Own Business",
        "Careers",
        "Investment Theory",
        "Banking and Credit"
      ],
      "GQ0" => [
        "Lit",
        "Sports",
        "Games",
        "Film, TV and Video",
        "Elementary School (6-12)",
        "Junior High School (12-14)",
        "High School (13-17)",
        "College Prep",
        "Pop/Rap/Rock",
        "Metal",
        "Country/Jazz/Other",
        "Fashion",
        "Hobbies",
        "Wheels"
      ],
      "ZC3" => [
        "Road",
        "Europe",
        "Hotel/Motel/B&B",
        "NE/MidAtlantic",
        "Southeast",
        "Midwest/Plains/Rockies",
        "West/Southwest",
        "Caribbean",
        "Theme Parks",
        "Afloat",
        "Pacific",
        "International",
        "Latin America",
        "Air Trael",
      ],
      "ZC4" => [
        "San Francisco Quake",
        "Quake/Emotional",
        "Quake/Location",
        "Abortion",
        "Flag Burning",
        "Caital Gains Tax",
        "NASA",
        "Supreme Court"
      ]
    }

    # Insert topics
    for {club_handle, topics} <- topics_by_club do
      for topic_title <- topics do
        # Escape single quotes in topic titles
        safe_title = String.replace(topic_title, "'", "''")

        execute """
        INSERT INTO topic (club_id, title, closed, inserted_at, updated_at)
        SELECT id, '#{safe_title}', false, NOW(), NOW()
        FROM club
        WHERE handle = '#{club_handle}';
        """
      end
    end
  end

  def down do
    # Delete all topics and clubs (posts will be cascade deleted if any exist)
    execute "DELETE FROM topic;"
    execute "DELETE FROM club;"
    end
end
