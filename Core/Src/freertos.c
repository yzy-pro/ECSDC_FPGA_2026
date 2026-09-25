/* USER CODE BEGIN Header */
/**
  ******************************************************************************
  * File Name          : freertos.c
  * Description        : Code for freertos applications
  ******************************************************************************
  * @attention
  *
  * Copyright (c) 2026 STMicroelectronics.
  * All rights reserved.
  *
  * This software is licensed under terms that can be found in the LICENSE file
  * in the root directory of this software component.
  * If no LICENSE file comes with this software, it is provided AS-IS.
  *
  ******************************************************************************
  */
/* USER CODE END Header */

/* Includes ------------------------------------------------------------------*/
#include "FreeRTOS.h"
#include "task.h"
#include "main.h"
#include "cmsis_os.h"

/* Private includes ----------------------------------------------------------*/
/* USER CODE BEGIN Includes */

/* USER CODE END Includes */

/* Private typedef -----------------------------------------------------------*/
/* USER CODE BEGIN PTD */

/* USER CODE END PTD */

/* Private define ------------------------------------------------------------*/
/* USER CODE BEGIN PD */

/* USER CODE END PD */

/* Private macro -------------------------------------------------------------*/
/* USER CODE BEGIN PM */

/* USER CODE END PM */

/* Private variables ---------------------------------------------------------*/
/* USER CODE BEGIN Variables */

/* USER CODE END Variables */
/* Definitions for DebugTask */
osThreadId_t DebugTaskHandle;
const osThreadAttr_t DebugTask_attributes = {
  .name = "DebugTask",
  .stack_size = 256 * 4,
  .priority = (osPriority_t) osPriorityRealtime,
};
/* Definitions for Bmi088Task */
osThreadId_t Bmi088TaskHandle;
const osThreadAttr_t Bmi088Task_attributes = {
  .name = "Bmi088Task",
  .stack_size = 256 * 4,
  .priority = (osPriority_t) osPriorityRealtime,
};
/* Definitions for JetsonTask */
osThreadId_t JetsonTaskHandle;
const osThreadAttr_t JetsonTask_attributes = {
  .name = "JetsonTask",
  .stack_size = 256 * 4,
  .priority = (osPriority_t) osPriorityNormal,
};
/* Definitions for JetsonTask2 */
osThreadId_t JetsonTask2Handle;
const osThreadAttr_t JetsonTask2_attributes = {
  .name = "JetsonTask2",
  .stack_size = 256 * 4,
  .priority = (osPriority_t) osPriorityNormal,
};
/* Definitions for Bmi088AccGpioExtiQueue */
osMessageQueueId_t Bmi088AccGpioExtiQueueHandle;
const osMessageQueueAttr_t Bmi088AccGpioExtiQueue_attributes = {
  .name = "Bmi088AccGpioExtiQueue"
};
/* Definitions for Bmi088GyroGpioExtiQueue */
osMessageQueueId_t Bmi088GyroGpioExtiQueueHandle;
const osMessageQueueAttr_t Bmi088GyroGpioExtiQueue_attributes = {
  .name = "Bmi088GyroGpioExtiQueue"
};
/* Definitions for Bmi088TempPeriodElapsed */
osMessageQueueId_t Bmi088TempPeriodElapsedHandle;
const osMessageQueueAttr_t Bmi088TempPeriodElapsed_attributes = {
  .name = "Bmi088TempPeriodElapsed"
};
/* Definitions for Bmi088StatusQueue */
osMessageQueueId_t Bmi088StatusQueueHandle;
const osMessageQueueAttr_t Bmi088StatusQueue_attributes = {
  .name = "Bmi088StatusQueue"
};
/* Definitions for Bmi088Status2Queue */
osMessageQueueId_t Bmi088Status2QueueHandle;
const osMessageQueueAttr_t Bmi088Status2Queue_attributes = {
  .name = "Bmi088Status2Queue"
};
/* Definitions for Bmi088SpiSem */
osSemaphoreId_t Bmi088SpiSemHandle;
const osSemaphoreAttr_t Bmi088SpiSem_attributes = {
  .name = "Bmi088SpiSem"
};
/* Definitions for Bmi088GyroBufferSem */
osSemaphoreId_t Bmi088GyroBufferSemHandle;
const osSemaphoreAttr_t Bmi088GyroBufferSem_attributes = {
  .name = "Bmi088GyroBufferSem"
};
/* Definitions for Bmi088AccBufferSem */
osSemaphoreId_t Bmi088AccBufferSemHandle;
const osSemaphoreAttr_t Bmi088AccBufferSem_attributes = {
  .name = "Bmi088AccBufferSem"
};
/* Definitions for Bmi088TempBufferSem */
osSemaphoreId_t Bmi088TempBufferSemHandle;
const osSemaphoreAttr_t Bmi088TempBufferSem_attributes = {
  .name = "Bmi088TempBufferSem"
};

/* Private function prototypes -----------------------------------------------*/
/* USER CODE BEGIN FunctionPrototypes */

/* USER CODE END FunctionPrototypes */

void AppDebugTask(void *argument);
void AppBmi088Task(void *argument);
void AppJetsonTask(void *argument);
void AppJetsonTask2(void *argument);

void MX_FREERTOS_Init(void); /* (MISRA C 2004 rule 8.1) */

/**
  * @brief  FreeRTOS initialization
  * @param  None
  * @retval None
  */
void MX_FREERTOS_Init(void) {
  /* USER CODE BEGIN Init */

  /* USER CODE END Init */

  /* USER CODE BEGIN RTOS_MUTEX */
  /* add mutexes, ... */
  /* USER CODE END RTOS_MUTEX */

  /* Create the semaphores(s) */
  /* creation of Bmi088SpiSem */
  Bmi088SpiSemHandle = osSemaphoreNew(1, 1, &Bmi088SpiSem_attributes);

  /* creation of Bmi088GyroBufferSem */
  Bmi088GyroBufferSemHandle = osSemaphoreNew(1, 1, &Bmi088GyroBufferSem_attributes);

  /* creation of Bmi088AccBufferSem */
  Bmi088AccBufferSemHandle = osSemaphoreNew(1, 1, &Bmi088AccBufferSem_attributes);

  /* creation of Bmi088TempBufferSem */
  Bmi088TempBufferSemHandle = osSemaphoreNew(1, 1, &Bmi088TempBufferSem_attributes);

  /* USER CODE BEGIN RTOS_SEMAPHORES */
  /* add semaphores, ... */
  /* USER CODE END RTOS_SEMAPHORES */

  /* USER CODE BEGIN RTOS_TIMERS */
  /* start timers, add new ones, ... */
  /* USER CODE END RTOS_TIMERS */

  /* Create the queue(s) */
  /* creation of Bmi088AccGpioExtiQueue */
  Bmi088AccGpioExtiQueueHandle = osMessageQueueNew (1, 4, &Bmi088AccGpioExtiQueue_attributes);

  /* creation of Bmi088GyroGpioExtiQueue */
  Bmi088GyroGpioExtiQueueHandle = osMessageQueueNew (1, 4, &Bmi088GyroGpioExtiQueue_attributes);

  /* creation of Bmi088TempPeriodElapsed */
  Bmi088TempPeriodElapsedHandle = osMessageQueueNew (1, 4, &Bmi088TempPeriodElapsed_attributes);

  /* creation of Bmi088StatusQueue */
  Bmi088StatusQueueHandle = osMessageQueueNew (2, 12, &Bmi088StatusQueue_attributes);

  /* creation of Bmi088Status2Queue */
  Bmi088Status2QueueHandle = osMessageQueueNew (2, 12, &Bmi088Status2Queue_attributes);

  /* USER CODE BEGIN RTOS_QUEUES */
  /* add queues, ... */
  /* USER CODE END RTOS_QUEUES */

  /* Create the thread(s) */
  /* creation of DebugTask */
  DebugTaskHandle = osThreadNew(AppDebugTask, NULL, &DebugTask_attributes);

  /* creation of Bmi088Task */
  Bmi088TaskHandle = osThreadNew(AppBmi088Task, NULL, &Bmi088Task_attributes);

  /* creation of JetsonTask */
  JetsonTaskHandle = osThreadNew(AppJetsonTask, NULL, &JetsonTask_attributes);

  /* creation of JetsonTask2 */
  JetsonTask2Handle = osThreadNew(AppJetsonTask2, NULL, &JetsonTask2_attributes);

  /* USER CODE BEGIN RTOS_THREADS */
  /* add threads, ... */
  /* USER CODE END RTOS_THREADS */

  /* USER CODE BEGIN RTOS_EVENTS */
  /* add events, ... */
  /* USER CODE END RTOS_EVENTS */

}

/* USER CODE BEGIN Header_AppDebugTask */
/**
  * @brief  Function implementing the DebugTask thread.
  * @param  argument: Not used
  * @retval None
  */
/* USER CODE END Header_AppDebugTask */
__weak void AppDebugTask(void *argument)
{
  /* USER CODE BEGIN AppDebugTask */
  /* Infinite loop */
  for(;;)
  {
    osDelay(1);
  }
  /* USER CODE END AppDebugTask */
}

/* USER CODE BEGIN Header_AppBmi088Task */
/**
* @brief Function implementing the Bmi088Task thread.
* @param argument: Not used
* @retval None
*/
/* USER CODE END Header_AppBmi088Task */
__weak void AppBmi088Task(void *argument)
{
  /* USER CODE BEGIN AppBmi088Task */
  /* Infinite loop */
  for(;;)
  {
    osDelay(1);
  }
  /* USER CODE END AppBmi088Task */
}

/* USER CODE BEGIN Header_AppJetsonTask */
/**
* @brief Function implementing the JetsonTask thread.
* @param argument: Not used
* @retval None
*/
/* USER CODE END Header_AppJetsonTask */
__weak void AppJetsonTask(void *argument)
{
  /* USER CODE BEGIN AppJetsonTask */
  /* Infinite loop */
  for(;;)
  {
    osDelay(1);
  }
  /* USER CODE END AppJetsonTask */
}

/* USER CODE BEGIN Header_AppJetsonTask2 */
/**
* @brief Function implementing the JetsonTask2 thread.
* @param argument: Not used
* @retval None
*/
/* USER CODE END Header_AppJetsonTask2 */
__weak void AppJetsonTask2(void *argument)
{
  /* USER CODE BEGIN AppJetsonTask2 */
  /* Infinite loop */
  for(;;)
  {
    osDelay(1);
  }
  /* USER CODE END AppJetsonTask2 */
}

/* Private application code --------------------------------------------------*/
/* USER CODE BEGIN Application */

/* USER CODE END Application */

