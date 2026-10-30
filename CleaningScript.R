#Load Data
library(rvest)
library(dplyr)
library(stringr)
library(janitor)
library(purrr)
library(nflreadr)
library(ggplot2)
library(tidytext)

page <- read_html("https://en.wikipedia.org/wiki/2010_NFL_draft")

# Exploration: find which table holds the picks (~255 rows)
tables <- html_table(page, fill = TRUE)
length(tables)
lapply(tables, dim)

# Exploration: inspect structure
draft_raw <- tables[[7]]
names(draft_raw)
head(draft_raw, 10)
tail(draft_raw, 5)

# Row(s) where Pick isn't just a number
draft_raw[!grepl("^[0-9]+$", draft_raw$Pick), ]

# Every value in the round column
unique(draft_raw$Rnd.)

# Full player names, to see how the Pro Bowl sign appears
head(draft_raw$Player, 20)

# Drop empty columns and standardize column names
draft_2010 <- draft_raw[, names(draft_raw) != ""] |>
  clean_names()

# Pull the Pro Bowl dagger out of the player name
draft_2010 <- draft_2010 |>
  mutate(
    pro_bowl = str_detect(player, "†"),
    player   = str_squish(str_remove(player, "†"))
  )

head(draft_2010)

# Split round number and pick type
draft_2010 <- draft_2010 |>
  mutate(
    pick_type = if_else(str_detect(rnd, "\\^"), "supplemental compensatory",
                        if_else(str_detect(rnd, "\\*"), "compensatory",
                                "regular")),
    rnd = as.integer(str_extract(rnd, "^[0-9]+"))
  )

# Remove forfeited picks and make pick numeric
draft_2010 <- draft_2010 |>
  filter(str_detect(pick, "^[0-9]+$")) |>
  mutate(pick = as.integer(pick))

# Checks
nrow(draft_2010)
count(draft_2010, pick_type)

################################################################################

#Repeat for all years

#Scrape every year's draft table
scrape_year <- function(year) {
  url <- paste0("https://en.wikipedia.org/wiki/", year, "_NFL_draft")
  tables <- read_html(url) |> html_table()
  
  # Find the picks table by its columns
  is_picks <- map_lgl(tables, function(t) any(grepl("pick", names(t), ignore.case = TRUE)) &
                        any(grepl("player", names(t), ignore.case = TRUE)))
  candidates <- tables[is_picks]
  
  if (length(candidates) == 0) {
    warning("No picks table found for ", year)
    return(NULL)
  }
  # If several tables match, keep the biggest one
  candidates[[which.max(map_int(candidates, nrow))]]
}

raw_list <- map(2000:2024, scrape_year)
names(raw_list) <- 2000:2024

# Save the untouched scrapes
dir.create("data/raw", recursive = TRUE, showWarnings = FALSE)
saveRDS(raw_list, "data/raw/wikipedia_draft_raw.rds")

# Checks
map_int(raw_list, nrow)
map(raw_list, names)

# Clean each year and combine
clean_year <- function(tbl, year) {
  tbl[, names(tbl) != ""] |>
    mutate(across(everything(), as.character)) |>
    clean_names() |>
    mutate(
      player = str_squish(player),                                # normalize hidden spaces
      player = str_replace(player, "^(.+?), (.+?)(\\2 .*)$", "\\3"),  # remove sort keys
      player = str_remove(player, ' "[^"]*"'),                    # remove quoted nicknames
      player = str_replace_all(player, "\u2013", "-")             # en dash -> hyphen
    ) |>
    mutate(
      year         = year,
      hall_of_fame = str_detect(player, "‡"),
      pro_bowl     = str_detect(player, "[†‡]"),
      player       = str_squish(str_remove_all(player, "[†‡]")),
      pick_type    = if_else(str_detect(rnd, "\\^"), "supplemental compensatory",
                             if_else(str_detect(rnd, "\\*"), "compensatory",
                                     "regular")),
      rnd          = as.integer(str_extract(rnd, "^[0-9]+"))
    ) |>
    filter(str_detect(pick, "^[0-9]+$")) |>
    mutate(pick = as.integer(pick)) |>
    relocate(year)
}

draft <- map2(raw_list, 2000:2024, clean_year) |> list_rbind()

# Checks
nrow(draft)

# Years where picks don't run 1..n cleanly should return 0 rows
draft |>
  group_by(year) |>
  summarise(n = n(), max_pick = max(pick), dupes = sum(duplicated(pick))) |>
  filter(n != max_pick | dupes > 0)

# Any round values that didn't convert
unique(draft$rnd)

# Player names that still have symbols left over
draft |>
  filter(str_detect(player, "[^\\p{L} .'-]")) |>
  select(year, pick, player)

# Every position label used
sort(unique(draft$pos))

# Group positions
draft <- draft |>
  mutate(
    pos_group = case_when(
      pos == "QB"                         ~ "QB",
      pos %in% c("RB", "FB")              ~ "RB",
      pos == "WR"                         ~ "WR",
      pos %in% c("TE", "TE/FB")           ~ "TE",
      pos %in% c("C", "G", "T")           ~ "OL",
      pos %in% c("DE", "DT", "NT")        ~ "DL",
      pos %in% c("LB", "ILB", "OLB")      ~ "LB",
      pos %in% c("CB", "S", "FS", "SS")   ~ "DB",
      pos %in% c("K", "P", "LS")          ~ "ST"
    )
  )

# Checks
count(draft, pos_group)
draft |> filter(is.na(pos_group)) |> count(pos)

# Do the safety labels change over time?
draft |>
  filter(pos %in% c("S", "FS", "SS")) |>
  count(year, pos) |>
  tidyr::pivot_wider(names_from = pos, values_from = n, values_fill = 0)

#check where specific positions appear
draft |>
  filter(pos %in% c("FS", "SS", "ILB", "OLB", "NT", "TE/FB")) |>
  count(year, pos) |>
  print(n = Inf)

#check college counts and different listings
draft |>
  filter(str_detect(college, "\\(|[A-Z]{2,}|\\.")) |>
  count(college) |>
  print(n = Inf)

draft |>
  filter(str_detect(college,
                    "Louisiana State|Southern Cal|Brigham|North Carolina State|Central Florida|Texas Christian|^Miami$|Mississippi|Ole Miss|Pitt|Connecticut|Massachusetts|Florida International|Nevada")) |>
  count(college) |>
  print(n = Inf)

draft <- draft |>
  mutate(college = str_replace_all(college, "\u2013", "-"))

#fix connecticut mismatch.
draft <- draft |>
  mutate(
    college = str_replace_all(college, "\u2013", "-"),
    college = if_else(college == "UConn", "Connecticut", college)
  )

# Check: should show only Connecticut
draft |> filter(str_detect(college, "Conn")) |> count(college)

picks_nfl <- load_draft_picks() |>
  filter(season >= 2000, season <= 2024)

names(picks_nfl)
head(picks_nfl, 5)

# Join All-Pro data from nflreadr
nfl_small <- picks_nfl |>
  select(
    year         = season,
    pick,
    nfl_round    = round,
    nfl_team     = team,
    nfl_name     = pfr_player_name,
    nfl_position = position,
    nfl_college  = college,
    allpro,
    probowls,
    nfl_hof      = hof
  )

joined <- draft |>
  left_join(nfl_small, by = c("year", "pick"))

# Checks
nrow(joined) == nrow(draft)                                  
anti_join(draft, nfl_small, by = c("year", "pick")) |> nrow()  
anti_join(nfl_small, draft, by = c("year", "pick")) |> nrow() 
sum(joined$rnd != joined$nfl_round, na.rm = TRUE)
summary(joined$allpro) 
joined |> count(pro_bowl, nfl_pro_bowl = probowls > 0) 

# Names that differ between sources
joined |>
  filter(player != nfl_name) |>
  select(year, pick, player, nfl_name) |>
  print(n = 30)


# Compare names between sources

#fix accents and normalize names per pick
norm_name <- function(x) {
  x |>
    stringi::stri_trans_general("Latin-ASCII") |>
    str_to_lower() |>
    str_remove_all("\\b(jr|sr|ii|iii|iv)\\b") |>
    str_remove_all("[^a-z]")
}

joined <- joined |>
  mutate(name_match = case_when(
    player == nfl_name                       ~ "exact",
    norm_name(player) == norm_name(nfl_name) ~ "formatting only",
    TRUE                                     ~ "different name"
  ))

count(joined, name_match)

# The 8 Pro Bowl disagreements
joined |>
  filter(pro_bowl != (probowls > 0)) |>
  select(year, pick, player, pro_bowl, probowls)

# Save clean data
dir.create("data/clean", recursive = TRUE, showWarnings = FALSE)
write.csv(joined, "data/clean/nfl_draft_2000_2024_clean.csv", row.names = FALSE)

# Plot
plot_data <- joined |>
  filter(pos_group != "ST", allpro > 0) |>
  group_by(pos_group, college) |>
  summarise(allpro_players = n(), .groups = "drop") |>
  group_by(pos_group) |>
  arrange(desc(allpro_players), college, .by_group = TRUE) |> 
  slice_head(n = 5) |>
  ungroup() |>
  mutate(
    pos_group = factor(pos_group, levels = c("QB", "RB", "WR", "TE", "OL", "DL", "LB", "DB")),
    college_ordered = reorder_within(college, allpro_players, pos_group)
  )

ggplot(plot_data, aes(x = allpro_players, y = college_ordered)) +
  geom_col(fill = "#2a78d6", width = 0.7) +
  scale_y_reordered() +
  scale_x_continuous(expand = expansion(mult = c(0, 0.05))) +
  facet_wrap(~ pos_group, scales = "free_y", ncol = 4) +
  labs(
    title    = "Which colleges produce All-Pro players at each position?",
    subtitle = "Top 5 colleges by number of All-Pro players drafted, 2000–2024",
    x        = "Players with at least one All-Pro selection",
    y        = NULL
  ) +
  theme_minimal(base_size = 11) +
  theme(
    panel.grid.major.y  = element_blank(),
    panel.grid.minor    = element_blank(),
    strip.text          = element_text(face = "bold", hjust = 0),
    plot.title.position = "plot"
  )

dir.create("figures", showWarnings = FALSE)
ggsave("figures/top_colleges_allpro.png", width = 11, height = 6, dpi = 300, bg = "white")