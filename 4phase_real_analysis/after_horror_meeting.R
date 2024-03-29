library(tidyverse)
library(ggpubr)
library(ordinal)
library(optimx)
library(stats)
library(data.table)
library(boot)

#data_by_weeks <- data_by_weeks[!(data_by_weeks$external_id %in% c("f1308", "bb8d0", "343ab", "9d7d1", "3fe63", "57ea9")), ]
all_data <- read_csv("phase4_current_results_p1204.csv", col_types = "fnnnnnnnnnnnncc")

conditions <- list(
  full_all_weeks = list(all_data$n < 8, all_data$week < 26),
  full_is7_weeks = list(all_data$n == 7, all_data$week < 26),
  full_less7_weeks = list(all_data$n < 7, all_data$week < 26),
  full_all_nat = list(all_data$n < 8, all_data$week < 14),
  full_is7_nat = list(all_data$n == 7, all_data$week < 14),
  full_less7_nat = list(all_data$n < 7, all_data$week < 14),
  full_all_slow = list(all_data$n < 8, all_data$week > 13),
  full_is7_slow = list(all_data$n == 7, all_data$week > 13),
  full_less7_slow = list(all_data$n < 7, all_data$week > 13)
)



# Different classes of weighting functions ============================
kumaraswamy_weights <- function(steps, a, b){
  kum_weights <- rep(0, length(steps) - 1)
  for (i in 2:length(steps)){
    kum_weights[i-1] = (1 - steps[i-1]^a)^b - (1 - steps[i]^a)^b
  }
  return(kum_weights)
}

kum_par <- c(1,1, 0.6,1, 0.9,1, 1,0.5, 5,0.9, 0.5,0.5, 0.9,0.9, 5,5, 3,6, 2,6)
dim(kum_par) <- c(2, 10)
kum_par <- t(kum_par)
colnames(kum_par) <- c("a", "b")

f_mean <- function(x) {
  tmp <- x[,1]
  tmp[is.na(x[,1])] <- 0
  norm <- rep(1, nrow(x))
  norm[is.na(x[,1])] <- 0
  for (i in c(2:6)){
    tmp_norm <- rep(1, nrow(x))
    tmp_norm[is.na(x[,i])] <- 0
    norm <- norm + tmp_norm
    tmp_na <- x[,i]
    tmp_na[is.na(tmp_na)] <- 0
    tmp <- tmp + tmp_na
  }
  return(tmp / norm)
}

f_min <- function(x) {
  tmp <- x[,1]
  tmp[is.na(x[,1])] <- Inf  # Initialize with positive infinity
  for (i in c(2:6)){
    tmp_na <- x[,i]
    tmp_na[is.na(tmp_na)] <- Inf  # Treat missing values as positive infinity
    tmp <- pmin(tmp, tmp_na)  # Calculate the element-wise minimum
  }
  tmp[tmp == Inf] <- NA  # Replace positive infinity with NA
  return(tmp)
}

result_df <- data.frame(Condition = character(0), ModelType = character(0), AIC = numeric(0))

for (condition_name in names(conditions)) {
  condition <- conditions[[condition_name]]
  data_by_weeks <- all_data %>% filter(!!!condition)
  data_by_weeks$f_mean = f_mean(as.matrix(data_by_weeks[,c("mo", "tu", "we", "th", "fr", "sa")]))
  data_by_weeks$f_min = f_min(as.matrix(data_by_weeks[,c("mo", "tu", "we", "th", "fr", "sa")]))
  data_by_weeks$os <- factor(data_by_weeks$q2, ordered = TRUE, 
                           levels = c(1, 2, 3, 4, 5))

  steps <- c(0, 1/6, 2/6, 3/6, 4/6, 5/6, 6/6)

  f_kum <- function(x, steps, a, b) {
    norm_vec <- t(replicate(nrow(x), kumaraswamy_weights(steps, a, b)))
    norm_vec[is.na(x)] <- 0
    rowSums(x * norm_vec, na.rm = TRUE) / rowSums(norm_vec)
  }

  objective_fun <- function(params, df, steps) {
    a <- params[1]
    b <- params[2]
  
    df$tmp <- f_kum(as.matrix(df[,c("mo", "tu", "we", "th", "fr", "sa")]), 
                  steps, a, b)
  
    model <- clm(os ~ tmp, data = df)  
  
    return(AIC(model))  
  }

  best_AIC <- 10^9
  opt_param <- 0
  for (i in 1:nrow(kum_par)){
    init_params <- kum_par[i,]
    lower_bounds <- c(0.00001, 0.00001)
    opt_data <- data_by_weeks 
  
    opt_result <- optimx(init_params, objective_fun, method="L-BFGS-B", 
                       lower=lower_bounds, df = opt_data, steps = steps)
  
    best_params <- opt_result
    print(best_params)
    if (best_params$value < best_AIC)
    {
      best_AIC <- best_params$value
      opt_param <- best_params
    }
  }

  data_by_weeks$f_best_fun <- f_kum(as.matrix(
    data_by_weeks[,c("mo", "tu", "we", "th", "fr", "sa")]), 
    steps, opt_param$a, opt_param$b)
  opt_model <- clm(os ~ f_best_fun, data = data_by_weeks)
  summary(opt_model)

  cor_plot_data <- data_by_weeks %>%
    group_by(week) %>%
    summarize(f_best_fun = first(f_best_fun), mos = mean(q2))

  predicted_probs <- predict(opt_model, newdata = cor_plot_data, type = "prob")
  # Convert predicted_probs from list to matrix
  predicted_probs_matrix <- do.call(rbind, predicted_probs)
  # Create a vector of weights
  weights <- matrix(rep(c(1,2,3,4,5), nrow(cor_plot_data)), nrow = nrow(cor_plot_data), ncol = 5, byrow = TRUE)
  # Calculate the weighted mean of the probabilities
  cor_plot_data$model <- rowSums(predicted_probs_matrix * weights) 
  cor_plot_data %>%
    mutate(content_type = ifelse(week < 14, "nature", "slowmo")) %>%
    ggplot(aes(model, mos, color = content_type)) + geom_point()

  cor_plot_data %>% ggplot(aes(model, mos)) + geom_point() + stat_cor(method = "pearson", label.x = 2.5, label.y = 5) 

  ggplot(NULL, aes(steps[2:7], kumaraswamy_weights(steps, opt_param$a, opt_param$b))) + 
    geom_point()


  AIC(opt_model)
  summary(opt_model)

  if (condition_name == 'full_is7_weeks' || condition_name == 'full_is7_nat' || condition_name == 'full_is7_slow') {
    glz_data <- data_by_weeks
    glz_data$os <- factor(glz_data$q2, ordered = TRUE,levels = c(1, 2, 3, 4, 5))
    model_glz1 <- clm(os ~ mo + tu + we + th + fr + sa, data = glz_data)  


    glz_data %<>%
      mutate(motu = (mo + tu)/2) %>%
      mutate(weth = (we + th)/2) %>%
      mutate(frsa = (fr + sa)/2)
    model_glz2 <- clm(os ~ motu + weth + frsa, data = glz_data)  
    
    aic_glz1 <- AIC(model_glz1)
    result_df <- rbind(result_df, data.frame(Condition = condition_name, ModelType = 'glz1', AIC = aic_glz1))
    aic_glz2 <- AIC(model_glz2)
    result_df <- rbind(result_df, data.frame(Condition = condition_name, ModelType = 'glz2', AIC = aic_glz2))
    

  } else {
    # Set AIC value to 'NA' for specific conditions
    result_df <- rbind(result_df, data.frame(Condition = condition_name, ModelType = 'model_glz1', AIC = NA))
    result_df <- rbind(result_df, data.frame(Condition = condition_name, ModelType = 'model_glz2', AIC = NA))
  }


  model_mean <- clm(os ~ f_mean, data = data_by_weeks)
  model_min <- clm(os ~ f_min, data = data_by_weeks)

  aic_min <- AIC(model_min)
  result_df <- rbind(result_df, data.frame(Condition = condition_name, ModelType = 'min', AIC = aic_min))
  aic_mean <- AIC(model_mean)
  result_df <- rbind(result_df, data.frame(Condition = condition_name, ModelType = 'mean', AIC = aic_mean))
  aic_model <- AIC(opt_model) + 4
  result_df <- rbind(result_df, data.frame(Condition = condition_name, ModelType = 'model', AIC = aic_model))

}
  