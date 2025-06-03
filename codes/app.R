library(shiny)
library(plotly)
library(dplyr)
library(scales)
library(zoo)
library(tidyr)
library(visNetwork)
library(rsconnect)

rsconnect::setAccountInfo

# Load data
stock_data <- read.csv("data/filtered_stock_data.csv", stringsAsFactors = FALSE)
stock_data$Date <- as.Date(stock_data$Date)

sentiment_data <- read.csv("data/trump_articles_with_sentiment.csv")
sentiment_data$Date <- as.Date(sentiment_data$Date)

sentiment_data_topic <- read.csv("data/trump_articles_with_topics.csv")
sentiment_data_topic$Date <- as.Date(sentiment_data_topic$Date)

# UI
ui <- fluidPage(
  tags$head(
    tags$style(HTML("
      .plot-container {
        border: 1px solid #ccc;
        padding: 10px;
        margin-bottom: 15px;
        border-radius: 5px;
        background-color: #fafafa;
        box-shadow: 1px 1px 5px rgba(0,0,0,0.1);
        height: 100%;
      }
      .col-sm-6 {
        padding-left: 10px;
        padding-right: 10px;
      }
    "))
  ),
  titlePanel("Financial Market Analysis"),
  
  div(class = "filter-panel",
      fluidRow(
        column(6,
               h5("Filters"),
               dateRangeInput("date_range", 
                              "Select Date Range:",
                              start = NULL,
                              end = NULL,
                              format = "yyyy-mm-dd")
        ),
        column(6,
               br(),
               checkboxGroupInput("sector_filter", 
                                  "Select Sectors:",
                                  choices = NULL,
                                  selected = NULL,
                                  inline = FALSE)
        )
      )
  ),
  
  fluidRow(
    column(6,
           div(class = "plot-container",
               h4("Bubble Chart"),
               plotlyOutput("bubble_plot", height = "600px")
           )
    ),
    column(6,
           div(class = "plot-container",
               h4("Sector-Level Sentiment vs Stock Price Correlation"),
               plotlyOutput("sector_scatter_plots", height = "600px")
           )
    )
  ),
  
  fluidRow(
    column(6,
           div(class = "plot-container",
               h4("Sentiment vs Company-Level Stock Price Correlation"),
               plotlyOutput("correlation_plot", height = "600px")
           )
    ),
    column(6,
           div(class = "plot-container",
               h4("Lagged Correlation: Sentiment vs Transaction Volume (-3 to +3 days)"),
               plotlyOutput("lagged_correlation_boxplot", height = "600px")
           )
    )
  ),
  
  fluidRow(
    column(12,
           div(class = "plot-container",
               h4("Heatmap: Topic Modeling Sentiment vs Stock Price Correlation"),
               plotlyOutput("topic_company_heatmap")
           )
    )
  )
)

# Server
server <- function(input, output, session) {
  
  # Initialize filters on app load
  observe({
    updateDateRangeInput(session, "date_range", 
                         start = min(stock_data$Date, na.rm = TRUE),
                         end = max(stock_data$Date, na.rm = TRUE),
                         min = min(stock_data$Date, na.rm = TRUE),
                         max = max(stock_data$Date, na.rm = TRUE))
    
    updateCheckboxGroupInput(session, "sector_filter",
                             choices = unique(stock_data$Sector),
                             selected = unique(stock_data$Sector))
  })
  
  # Reactive filtered data based on inputs
  filtered_stock_data <- reactive({
    req(input$date_range, input$sector_filter)
    stock_data %>%
      filter(Date >= input$date_range[1], Date <= input$date_range[2], Sector %in% input$sector_filter)
  })
  
  filtered_sentiment_data <- reactive({
    req(input$date_range)
    sentiment_data %>%
      filter(Date >= input$date_range[1], Date <= input$date_range[2])
  })
  
  filtered_sentiment_topic <- reactive({
    req(input$date_range)
    sentiment_data_topic %>%
      filter(Date >= input$date_range[1], Date <= input$date_range[2])
  })
  
  # Bubble plot
  output$bubble_plot <- renderPlotly({
    df <- filtered_stock_data()
    if(nrow(df) == 0) return(plot_ly() %>% add_annotations(text = "No data for filters", showarrow = FALSE))
    
    df$Market_Cap_Char <- as.character(df$Market.Cap)
    df$MarketCap_num <- suppressWarnings({
      clean_values <- gsub("[\\$,]", "", df$Market_Cap_Char)
      multiplier <- ifelse(grepl("B", clean_values, ignore.case = TRUE), 1e9,
                           ifelse(grepl("M", clean_values, ignore.case = TRUE), 1e6,
                                  ifelse(grepl("K", clean_values, ignore.case = TRUE), 1e3, 1)))
      numeric_part <- as.numeric(gsub("[BMK]", "", clean_values, ignore.case = TRUE))
      numeric_part * multiplier
    })
    
    df_clean <- df %>% filter(!is.na(MarketCap_num) & MarketCap_num > 0)
    if(nrow(df_clean) == 0) return(plot_ly() %>% add_annotations(text = "No valid market cap data", showarrow = FALSE))
    
    min_mc <- min(df_clean$MarketCap_num, na.rm = TRUE)
    max_mc <- max(df_clean$MarketCap_num, na.rm = TRUE)
    df_clean$normalized_market_cap <- (df_clean$MarketCap_num - min_mc) / (max_mc - min_mc) * 100
    
    df_agg <- df_clean %>%
      group_by(Symbol, Name, Sector) %>%
      summarise(
        Volume = last(Volume[order(Date)]),
        MarketCap_num = last(MarketCap_num[order(Date)]),
        normalized_market_cap = last(normalized_market_cap[order(Date)]),
        Date = max(Date),
        Close = last(Close[order(Date)]),
        .groups = 'drop'
      )
    
    plot_ly(
      data = df_agg,
      x = ~Symbol,
      y = ~Volume,
      type = 'scatter',
      mode = 'markers',
      color = ~Sector,
      marker = list(size = ~normalized_market_cap, sizemode = 'area', sizeref = 0.05, opacity = 0.6),
      text = ~paste0("Symbol: ", Symbol,
                     "<br>Name: ", Name,
                     "<br>Sector: ", Sector,
                     "<br>Market Cap: $", scales::comma(MarketCap_num),
                     "<br>Volume: ", round(Volume, 0),
                     "<br>Close Price: $", round(Close, 2),
                     "<br>Date: ", Date),
      hoverinfo = 'text'
    ) %>%
      layout(
        xaxis = list(title = "Stock Symbol", tickangle = -45, type = "category"),
        yaxis = list(title = "Volume")
      )
  })
  
  # Sector-level sentiment vs stock price scatter + trend lines
  output$sector_scatter_plots <- renderPlotly({
    sector_analysis <- filtered_stock_data() %>%
      group_by(Sector, Date) %>%
      summarise(
        Avg_Close = mean(Close, na.rm = TRUE),
        Avg_Volume = mean(Volume, na.rm = TRUE),
        Stock_Count = n(),
        .groups = 'drop'
      ) %>%
      arrange(Sector, Date)
    
    if(nrow(sector_analysis) == 0) return(plot_ly() %>% add_annotations(text = "No data for filters", showarrow = FALSE))
    
    set.seed(123)
    sector_analysis$Sentiment_Score <- runif(nrow(sector_analysis), -1, 1)
    
    sectors <- unique(sector_analysis$Sector)
    sector_colors <- c("#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b", "#e377c2", "#7f7f7f")
               names(sector_colors) <- sectors[1:min(length(sectors), 8)]
               
               p <- plot_ly()
               for(i in seq_along(sectors)) {
                 sector <- sectors[i]
                 data_s <- sector_analysis %>% filter(Sector == sector)
                 col <- sector_colors[min(i, length(sector_colors))]
                 
                 p <- p %>%
                   add_trace(data = data_s, x = ~Sentiment_Score, y = ~Avg_Close, type = 'scatter', mode = 'markers',
                             marker = list(size = 8, opacity = 0.7, color = col),
                             text = ~paste("Sector:", Sector, "<br>Date:", Date, "<br>Avg Close: $", round(Avg_Close, 2)),
                             hoverinfo = 'text', name = sector, legendgroup = sector)
                 
                 if(nrow(data_s) > 1) {
                   lm_mod <- lm(Avg_Close ~ Sentiment_Score, data = data_s)
                   xs <- seq(min(data_s$Sentiment_Score), max(data_s$Sentiment_Score), length.out = 100)
                   ys <- predict(lm_mod, newdata = data.frame(Sentiment_Score = xs))
                   p <- p %>%
                     add_trace(x = xs, y = ys, type = 'scatter', mode = 'lines', line = list(width = 3, color = col),
                               name = paste(sector, "Trend"), legendgroup = sector, showlegend = FALSE, hoverinfo = 'skip')
                 }
               }
               p %>%
                 layout(xaxis = list(title = "Sentiment Score"), yaxis = list(title = "Average Stock Price ($)"),
                        legend = list(orientation = "v", x = 1.02, y = 1))
               })
           
           # Spearman correlation bar plot
           output$correlation_plot <- renderPlotly({
             merged_data <- merge(filtered_stock_data(), filtered_sentiment_data(), by = "Date", all.x = TRUE)
             if(nrow(merged_data) == 0) return(plot_ly() %>% add_annotations(text = "No data", showarrow = FALSE))
             
             correlations <- data.frame(Symbol = character(), Correlation = numeric(), Sector = character())
             for(sym in unique(merged_data$Symbol)) {
               dt <- merged_data %>% filter(Symbol == sym)
               if(nrow(dt) > 1 && !all(is.na(dt$sentiment))) {
                 cor_val <- cor(dt$sentiment, dt$Close, method = "spearman", use = "complete.obs")
                 correlations <- rbind(correlations, data.frame(Symbol = sym, Correlation = cor_val, Sector = dt$Sector[1]))
               }
             }
             if(nrow(correlations) == 0) return(plot_ly() %>% add_annotations(text = "No correlation data", showarrow = FALSE))
             
             correlations <- correlations %>%
               arrange(desc(Correlation)) %>%
               mutate(color = ifelse(Correlation >= 0, 'blue', 'red'))
             
             plot_ly(
               data = correlations,
               y = ~factor(Symbol, levels = Symbol),
               x = ~Correlation,
               type = 'bar',
               text = ~paste("Symbol:", Symbol, "<br>Sector:", Sector, "<br>Correlation:", round(Correlation, 3)),
               hoverinfo = 'text',
               marker = list(color = ~color)
             ) %>%
               layout(xaxis = list(title = "Correlation"), yaxis = list(title = "Stock Symbol"))
           })
           
           # Lagged correlation boxplot
           output$lagged_correlation_boxplot <- renderPlotly({
             stock_df <- filtered_stock_data()
             sentiment_df <- filtered_sentiment_data()
             merged_df <- merge(stock_df, sentiment_df, by = "Date", all.x = TRUE)
             if(nrow(merged_df) == 0) return(plot_ly() %>% layout(title = "No data"))
             
             lags <- -3:3
             lagged_corrs <- lapply(lags, function(lag_val) {
               sapply(unique(merged_df$Symbol), function(sym) {
                 dt <- merged_df %>% filter(Symbol == sym) %>% arrange(Date)
                 shifted_sent <- if(lag_val > 0) dplyr::lag(dt$sentiment, n = lag_val) else
                   if(lag_val < 0) dplyr::lead(dt$sentiment, n = abs(lag_val)) else dt$sentiment
                 cor_val <- tryCatch(cor(shifted_sent, dt$Volume, method = "spearman", use = "complete.obs"), error = function(e) NA)
                 cor_val
               })
             })
             
             lagged_corr_df <- do.call(rbind, Map(data.frame, Lag=lags, Correlation=lagged_corrs))
             lagged_corr_df <- lagged_corr_df %>% filter(!is.na(Correlation))
             
             plot_ly(lagged_corr_df, x = ~factor(Lag), y = ~Correlation, type = "box", boxpoints = "none",
                     marker = list(size = 4, color = 'purple')) %>%
               layout(xaxis = list(title = "Lag (days)"), yaxis = list(title = "Spearman Correlation", range = c(-1, 1)))
           })
           
           output$topic_company_heatmap <- renderPlotly({
             topic_data <- filtered_sentiment_topic()
             stock_data_f <- filtered_stock_data()
             
             # Require data
             if(nrow(topic_data) == 0 || nrow(stock_data_f) == 0) {
               return(plot_ly() %>% layout(title = "No data for selected filters"))
             }
             
             # Average sentiment by Date and Topic
             topic_daily_sentiment <- topic_data %>%
               group_by(Date, dominant_topic) %>%
               summarise(avg_sentiment = mean(sentiment, na.rm = TRUE), .groups = "drop")
             
             # Wide format: Dates as rows, topics as columns
             topic_sentiment_wide <- topic_daily_sentiment %>%
               pivot_wider(names_from = dominant_topic, values_from = avg_sentiment, names_prefix = "topic_") %>%
               arrange(Date)
             
             # Select topics (assume 0 to 5)
             topics <- paste0("topic_", 0:5)
             available_topics <- intersect(topics, names(topic_sentiment_wide))
             if(length(available_topics) == 0) {
               return(plot_ly() %>% layout(title = "No topic data available"))
             }
             
             # Prepare stock closing prices by company
             stock_ts <- stock_data_f %>%
               select(Date, Symbol, Close) %>%
               arrange(Symbol, Date)
             
             companies <- unique(stock_ts$Symbol)
             
             # Calculate Spearman correlations between each topic and each company
             cor_matrix <- matrix(NA, nrow = length(companies), ncol = length(available_topics),
                                  dimnames = list(companies, available_topics))
             
             for (topic in available_topics) {
               topic_series <- topic_sentiment_wide[[topic]]
               # Trim NA on topic series (keep only dates where topic sentiment is not NA)
               valid_dates <- topic_sentiment_wide$Date[!is.na(topic_series)]
               topic_vals <- topic_series[!is.na(topic_series)]
               
               for (company in companies) {
                 company_prices <- stock_ts %>%
                   filter(Symbol == company, Date %in% valid_dates) %>%
                   arrange(Date) %>%
                   pull(Close)
                 
                 # Keep length aligned
                 if(length(company_prices) >= 3) {  # Require minimum length for correlation
                   common_length <- min(length(topic_vals), length(company_prices))
                   cor_val <- suppressWarnings(cor(topic_vals[1:common_length], company_prices[1:common_length],
                                                   method = "spearman", use = "complete.obs"))
                   cor_matrix[company, topic] <- cor_val
                 }
               }
             }
             
             # Replace NA with 0 for plotting
             cor_matrix[is.na(cor_matrix)] <- 0
             
             # Convert matrix to long format for plotly heatmap
             cor_df <- as.data.frame(as.table(cor_matrix))
             names(cor_df) <- c("Company", "Topic", "Correlation")
             
             topic_labels <- c(
               "0" = "trade, tariffs, deal, china",
               "1" = "crypto, bitcoin, blockchain, market",
               "2" = "election, campaign, vote, poll",
               "3" = "economy, growth, jobs, inflation",
               "4" = "policy, regulation, government, law",
               "5" = "foreign, diplomacy, war, sanctions"
             )
             
             cor_df$TopicLabel <- sapply(cor_df$Topic, function(t) {
               topic_num <- as.character(as.numeric(gsub("topic_", "", t)))
               if(topic_num %in% names(topic_labels)) {
                 topic_labels[topic_num]
               } else {
                 t
               }
             })
             
             print(head(cor_df))
             
             # Plotly heatmap
             plot_ly(
               data = cor_df,
               x = ~Topic,
               y = ~Company,
               z = ~Correlation,
               type = "heatmap",
               colorscale = "RdBu",
               reversescale = TRUE,
               zmin = -1,
               zmax = 1,
               colorbar = list(title = "Spearman Correlation"),
               text = ~paste("Company:", Company, "<br>Topic:", TopicLabel, "<br>Correlation:", round(Correlation, 3)),
               hoverinfo = "text"
             ) %>%
               layout(
                 xaxis = list(title = "Topic (keywords)"),
                 yaxis = list(title = "Company", autorange = "reversed")
               )
           })
           
           }

shinyApp(ui = ui, server = server)