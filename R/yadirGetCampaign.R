yadirGetCampaign <- function(
      Logins = getOption("ryandexdirect.user"), 
      States = c("OFF", "ON", "SUSPENDED", "ENDED", "CONVERTED", "ARCHIVED"),
      Types = c("TEXT_CAMPAIGN", "MOBILE_APP_CAMPAIGN", "DYNAMIC_TEXT_CAMPAIGN", "CPM_BANNER_CAMPAIGN", "SMART_CAMPAIGN", "UNIFIED_CAMPAIGN"),
      Statuses = c("ACCEPTED", "DRAFT", "MODERATION", "REJECTED"),
      StatusesPayment = c("DISALLOWED", "ALLOWED"),
      Token = NULL,
      AgencyAccount = getOption("ryandexdirect.agency_account"),
      TokenPath = yadirTokenPath()
  ) {
    start_time <- Sys.time()
    
    # Вспомогательная функция для обработки null значений
    handle_null <- function(value, default = NA) {
      if (is.null(value)) return(default)
      return(value)
    }
    
    create_query_body <- function(States, Types, Statuses, StatusesPayment, lim) {
      list(
        method = "get",
        params = list(
          SelectionCriteria = list(
            States = States,
            Types = Types,
            StatusesPayment = StatusesPayment,
            Statuses = Statuses
          ),
          FieldNames = c(
            "Id", "Name", "Type", "StartDate", "Status", "StatusPayment", "SourceId", "State",
            "Statistics", "Funds", "Currency", "DailyBudget", "ClientInfo"
          ),
          TextCampaignFieldNames = c("BiddingStrategy", "AttributionModel"),
          MobileAppCampaignFieldNames = list("BiddingStrategy"),
          DynamicTextCampaignFieldNames = c("BiddingStrategy", "AttributionModel"),
          CpmBannerCampaignFieldNames = list("BiddingStrategy"),
          Page = list(Limit = 10000, Offset = lim)
        )
      )
    }
    
    process_campaign_data <- function(campaign, login) {
      tibble(
        Id = handle_null(campaign$Id),
        Name = handle_null(campaign$Name),
        Type = handle_null(campaign$Type),
        Status = handle_null(campaign$Status),
        State = handle_null(campaign$State),
        StatusPayment = handle_null(campaign$StatusPayment),
        SourceId = handle_null(campaign$SourceId),
        DailyBudgetAmount = handle_null(campaign$DailyBudget$Amount) / 1000000,
        DailyBudgetMode = handle_null(campaign$DailyBudget$Mode),
        Currency = handle_null(campaign$Currency),
        StartDate = handle_null(campaign$StartDate),
        Impressions = handle_null(campaign$Statistics$Impressions),
        Clicks = handle_null(campaign$Statistics$Clicks),
        ClientInfo = handle_null(campaign$ClientInfo),
        FundsMode = handle_null(campaign$Funds$Mode),
        CampaignFundsBalance = handle_null(campaign$Funds$CampaignFunds$Balance) / 1000000,
        CampaignFundsBalanceBonus = handle_null(campaign$Funds$CampaignFunds$BalanceBonus) / 1000000,
        CampaignFundsSumAvailableForTransfer = handle_null(campaign$Funds$CampaignFunds$SumAvailableForTransfer) / 1000000,
        SharedAccountFundsRefund = handle_null(campaign$Funds$SharedAccountFunds$Refund) / 1000000,
        SharedAccountFundsSpend = handle_null(campaign$Funds$SharedAccountFunds$Spend) / 1000000,
        TextCampBidStrategySearchType = handle_null(campaign$TextCampaign$BiddingStrategy$Search$BiddingStrategyType, ""),
        TextCampBidStrategyNetworkType = handle_null(campaign$TextCampaign$BiddingStrategy$Network$BiddingStrategyType, ""),
        TextCampAttributionModel = handle_null(campaign$TextCampaign$AttributionModel, ""),
        DynCampBidStrategySearchType = handle_null(campaign$DynamicTextCampaign$BiddingStrategy$Search$BiddingStrategyType, ""),
        DynCampBidStrategyNetworkType = handle_null(campaign$DynamicTextCampaign$BiddingStrategy$Network$BiddingStrategyType, ""),
        DynCampAttributionModel = handle_null(campaign$DynamicTextCampaign$AttributionModel, ""),
        MobCampBidStrategySearchType = handle_null(campaign$MobileAppCampaign$BiddingStrategy$Search$BiddingStrategyType, ""),
        MobCampBidStrategyNetworkType = handle_null(campaign$MobileAppCampaign$BiddingStrategy$Network$BiddingStrategyType, ""),
        CpmBannerBidStrategySearchType = handle_null(campaign$CpmBannerCampaign$BiddingStrategy$Search$BiddingStrategyType, ""),
        CpmBannerBidStrategyNetworkType = handle_null(campaign$CpmBannerCampaign$BiddingStrategy$Network$BiddingStrategyType, ""),
        Login = login
      )
    }
    
    lim <- 0
    packageStartupMessage("Processing", appendLF = FALSE)
    
    result <- tibble()
    
    while (lim != "stoped") {
      query_body <- create_query_body(States, Types, Statuses, StatusesPayment, lim)
      print(query_body)
      
      for (login in Logins) {
        Token <- tech_auth(login = login, token = Token, AgencyAccount = AgencyAccount, TokenPath = TokenPath)
        
        response <- request("https://api.direct.yandex.com/json/v5/campaigns") %>%
          req_method("POST") %>%
          req_headers(
            Authorization = paste("Bearer", Token),
            `Accept-Language` = "ru",
            `Client-Login` = login
          ) %>%
          req_body_json(query_body) %>%
          req_perform()
        
        data_raw <- resp_body_json(response)
        
        if (!is.null(data_raw$error)) {
          stop(paste0(data_raw$error$error_string, " - ", data_raw$error$error_detail))
        }
        
        if (!is.null(data_raw$result$Campaigns)) {
          df <- map_dfr(data_raw$result$Campaigns, process_campaign_data, login = login)
          result <- bind_rows(result, df)
        }
      }
      
      packageStartupMessage(".", appendLF = FALSE)
      lim <- ifelse(is.null(data_raw$result$LimitedBy), "stoped", data_raw$result$LimitedBy + 1)
    }
    
    result <- result %>%
      mutate(
        Type = as.factor(Type),
        Status = as.factor(Status),
        State = as.factor(State),
        Currency = as.factor(Currency)
      )
    
    stop_time <- Sys.time()
    
    packageStartupMessage("Done", appendLF = TRUE)
    packageStartupMessage(paste0("Number of loaded campaigns: ", nrow(result)), appendLF = TRUE)
    packageStartupMessage(paste0("Processing duration: ", round(difftime(stop_time, start_time, units = "secs"), 0), " sec."), appendLF = TRUE)
    
    return(result)
}