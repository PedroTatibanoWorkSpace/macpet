#pragma once

/// Temperatura máxima entre os sensores de die da CPU (°C), ou -1 se indisponível.
double csensors_cpu_temperature(void);

/// Temperatura média da bateria (°C), ou -1 se indisponível.
double csensors_battery_temperature(void);
