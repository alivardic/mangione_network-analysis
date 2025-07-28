################################################################################
# Load All Libraires 
################################################################################
library(readr)
library(igraph)
library(tidyverse)
################################################################################
# Load All Datasets
################################################################################
# Disclaimer -- full_dataset.csv and cleaned_x_data-500k.csv are identical except for a cleaned_text column
# added from the Data-cleaning.ipymb file
df<- read_csv("Data/full_dataset.csv")
k500 <- read_csv("Data/cleaned_x_data-500k.csv")

# Created after Runnning stance detection on cleaned70k.csv earlier in project process
lmdata <- read_csv("Data/LM_70k_stance.csv")
btdata <- read_csv("Data/BT_70k_stance.csv")
uhcdata <- read_csv("Data/UHC_70k_stance.csv")


################################################################################
# Edgelist 
################################################################################
rtdf <- df %>%
  filter(`Engagement Type`== "RETWEET") %>%
  select(Author, `Thread Author`)

#remove all rows with space in the retweets
data <- rtdf[rtdf$`Thread Author` != "", ]

#get the frequencies
edgelist2 <- dplyr::summarise(dplyr::group_by(data, Author, `Thread Author`),count =n())

#Sort descending and remove duplicates pair just in case
decreasing_df <- edgelist2[order(edgelist2$count, decreasing = TRUE), ]
decreasing_df <- decreasing_df[!duplicated(decreasing_df[c(1,2)]), ]

#assign tags, in this case edges are directed, meaning username is connected to the retweeted user name
Type <- rep("Directed", nrow(decreasing_df))
decreasing_df$Type <- Type

#change column names
# Target == Person who retweeted the post (AUTHOR)
# Source == Original thread author (THREAD AUTHOR)
colnames(decreasing_df) <- c("Target", "Source", "Weight","Type")
decreasing_df <- decreasing_df[,c("Source", "Target", "Type", "Weight")]


################################################################################
# Pagerank
################################################################################
# Create igraph object
g <- graph_from_data_frame(decreasing_df, directed=TRUE)
E(g)$weight <- decreasing_df$Weight

# Compute PageRank
# https://igraph.org/r/html/1.3.2/page_rank.html
# Computed Google's Pagerank
pr <- page_rank(g, weights = E(g)$weight)$vector
pr_df <- data.frame(
  user = names(pr),
  pagerank = pr
) %>% arrange(desc(pagerank))


################################################################################
# Stance Classification
################################################################################
threads <- k500[, c("Thread Author", "original_text", "Url")]
k500 <- k500 %>% select(Author,`Thread Author`, original_text, Url)
lmdata <- lmdata %>% select(original_text, `gpt-4.1-mini_stance`, Url)
btdata <- btdata %>% select(original_text, `gpt-4.1-mini_stance`, Url)
uhcdata <- uhcdata %>% select(original_text, `gpt-4.1-mini_stance`, Url)

colnames(lmdata) <- c("original_text", "lm_stance", "Url")
colnames(btdata) <- c("original_text", "bt_stance", "Url")
colnames(uhcdata) <- c("original_text", "uhc_stance", "Url")

stanced <- k500 %>%
  left_join(lmdata, by = "Url") %>% distinct() %>% select(Author, `Thread Author`, Url, original_text.x, lm_stance) %>%
  left_join(btdata, by = "Url") %>% distinct() %>% select(Author, `Thread Author`, Url, original_text.x, lm_stance, bt_stance) %>%
  left_join(uhcdata, by = "Url") %>% distinct() %>% select(Author, `Thread Author`, Url, original_text.x, lm_stance, bt_stance, uhc_stance) %>%
  group_by(original_text.x) %>%
  fill(lm_stance, .direction = "downup") %>%
  fill(bt_stance, .direction = "downup") %>%
  fill(uhc_stance, .direction = "downup") %>%
  ungroup()

stanced %>% summarise(across(everything(), ~ sum(is.na(.))))

merged <- stanced %>%
  pivot_longer(cols = c(Author, `Thread Author`), 
               names_to = "Role", values_to = "User") %>%
  filter(!is.na(User)) %>% filter(!is.na(`lm_stance`)) %>% filter(!is.na(`bt_stance`))%>% filter(!is.na(`uhc_stance`))

#################################################################################
safe_var <- function(x) {
  v <- var(x, na.rm = TRUE)
  if (is.na(v)) return(0) else return(v)
}
###########################################################################################

stance_classification <- merged %>%
  group_by(User) %>%
  summarise(
    appearance = n(),
    lm_sum  = round(sum(lm_stance, na.rm = TRUE), 4),
    bt_sum  = round(sum(bt_stance, na.rm = TRUE), 4),
    uhc_sum = round(sum(uhc_stance, na.rm = TRUE), 4),
    lm_avg  = round(mean(lm_stance, na.rm = TRUE), 4),
    bt_avg  = round(mean(bt_stance, na.rm = TRUE), 4),
    uhc_avg = round(mean(uhc_stance, na.rm = TRUE), 4),
    lm_var  = safe_var(lm_stance),
    bt_var  = safe_var(bt_stance),
    uhc_var = safe_var(uhc_stance),
    .groups = "drop"
  ) %>%
  mutate(
    lm_label = case_when(
      lm_avg > 0 ~ "Mangione_pos",
      lm_avg < 0 ~ "Mangione_neg",
      lm_avg == 0 & lm_var == 0 ~ "lm_TrueNeutral",
      lm_avg == 0 & lm_var > 0 ~ "lm_Divided"
    ),
    bt_label = case_when(
      bt_avg > 0 ~ "Thompson_pos",
      bt_avg < 0 ~ "Thompson_neg",
      bt_avg == 0 & bt_var == 0 ~ "bt_TrueNeutral",
      bt_avg == 0 & bt_var > 0 ~ "bt_Divided"
    ),
    uhc_label = case_when(
      uhc_avg > 0 ~ "uhc_pos",
      uhc_avg < 0 ~ "uhc_neg",
      uhc_avg == 0 & uhc_var == 0 ~ "uhc_TrueNeutral",
      uhc_avg == 0 & uhc_var > 0 ~ "uhc_Divided"
    )
  )


################################################################################
# Edgelist + Stance Classification (Top 50k edges)
################################################################################
Pagerank <- pr_df %>%
  left_join(stance_classification, by = c("user" = "User"))

top50k <- decreasing_df[1:50000,]

# Create a vector of users from the top50k edgelist
top_users <- unique(c(top50k$Source, top50k$Target))

# Filter Pagerank to only include those users
Pagerank_filtered <- Pagerank %>%
  filter(user %in% top_users)

Pagerank_filtered <- Pagerank_filtered %>%
  rename(Id = user)


################################################################################
# Export csvs
################################################################################
write_csv(Pagerank_filtered, "edgelist.csv")
write_csv(top50k, "nodes_attr.csv")













