#define BLYNK_TEMPLATE_ID "TMPL6AmFvmyxo"
#define BLYNK_TEMPLATE_NAME "lasttermProjectIot"
#define BLYNK_AUTH_TOKEN "mAiaSX1z3qwSc8_3vmXUGyiX-RI9ClWq"

// Sau đó mới include Blynk
#include <BlynkSimpleEsp8266.h>


#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <Wire.h>
#include <BlynkSimpleEsp8266.h>
#include <ArduinoJson.h>
#include <MAX30100_PulseOximeter.h>

// Blynk credentials
char auth[] = "mAiaSX1z3qwSc8_3vmXUGyiX-RI9ClWq";
char ssid[] = "P906";
char pass[] = "213546987";

Adafruit_MPU6050 mpu;
PulseOximeter pox;

#define WINDOW_SIZE 200
float svm_buffer[WINDOW_SIZE];
float gyro_x_buffer[WINDOW_SIZE];
float gyro_y_buffer[WINDOW_SIZE];
float gyro_z_buffer[WINDOW_SIZE];
float svm_values[WINDOW_SIZE];
int buffer_index = 0;

bool fallDetected = false;
float heartRate = 0;
float spo2 = 0;

// Virtual pins
#define VIRTUAL_PIN_HEART_RATE 1
#define VIRTUAL_PIN_FALL_DETECTED 2
#define VIRTUAL_PIN_SPO2 3

void onBeatDetected() {
    Serial.println("Beat!");
}

void setup() {
  Serial.begin(115200);
  delay(100);

  // Initialize Blynk
  Blynk.begin(BLYNK_AUTH_TOKEN, ssid, pass, "blynk.cloud", 80);
  Serial.println("Blynk connected!");

  // Initialize MAX30100
  if (!pox.begin()) {
    Serial.println("Failed to find MAX30100 chip");
    while (1) delay(10);
  }
  Serial.println("MAX30100 Found!");
  pox.setOnBeatDetectedCallback(onBeatDetected);
  pox.setIRLedCurrent(MAX30100_LED_CURR_7_6MA);

  if (!mpu.begin()) {
    Serial.println("Failed to find MPU6050 chip");
    while (1) delay(10);
  }
  Serial.println("MPU6050 Found!");
  mpu.setAccelerometerRange(MPU6050_RANGE_16_G);
  mpu.setGyroRange(MPU6050_RANGE_2000_DEG);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);

  for (int i = 0; i < WINDOW_SIZE; i++) {
    svm_buffer[i]   = 0;
    gyro_x_buffer[i]= 0;
    gyro_y_buffer[i]= 0;
    gyro_z_buffer[i]= 0;
    svm_values[i]   = 0;
  }
}

void check_fall(float ax, float ay, float az, float gx, float gy, float gz) {
  float svm = sqrt(ax*ax + ay*ay + az*az) / 9.81;
  float abs_gx = abs(gx), abs_gy = abs(gy), abs_gz = abs(gz);

  svm_buffer[buffer_index]    = svm;
  gyro_x_buffer[buffer_index] = abs_gx;
  gyro_y_buffer[buffer_index] = abs_gy;
  gyro_z_buffer[buffer_index] = abs_gz;
  svm_values[buffer_index]    = svm;
  buffer_index = (buffer_index + 1) % WINDOW_SIZE;

  float max_svm = svm_buffer[0], max_gx = gyro_x_buffer[0], max_gy = gyro_y_buffer[0], max_gz = gyro_z_buffer[0];
  float sum = svm_values[0], sum_sq = svm_values[0]*svm_values[0], change = 0;
  for (int i = 1; i < WINDOW_SIZE; i++) {
    max_svm = max(max_svm, svm_buffer[i]);
    max_gx  = max(max_gx,  gyro_x_buffer[i]);
    max_gy  = max(max_gy,  gyro_y_buffer[i]);
    max_gz  = max(max_gz,  gyro_z_buffer[i]);
    sum    += svm_values[i];
    sum_sq += svm_values[i]*svm_values[i];
    change += abs(svm_values[i] - svm_values[i-1]);
  }
  float mean = sum / WINDOW_SIZE;
  float stdv = sqrt(sum_sq / WINDOW_SIZE - mean*mean);

  // Quy tắc cây quyết định
  if (max_svm <= 2.64) {
    if (max_gz <= 198.37) {
      if (max_gy <= 253.39) {
        fallDetected = false;
      } else {
        fallDetected = (max_gx > 128.35);
      }
    } else {
      fallDetected = true;
    }
  } else {
    if (max_gy <= 144.14) {
      if (max_svm <= 5.56) {
        fallDetected = false;
      } else {
        fallDetected = (change > 43.16);
      }
    } else {
      if (change <= 156.40) {
        fallDetected = true;
      } else {
        fallDetected = (max_svm > 9.28);
      }
    }
  }
}

void sendData() {
  // Update heart rate and SpO2 values
  pox.update();
  heartRate = pox.getHeartRate();
  spo2 = pox.getSpO2();

  // Send data to Blynk
  Blynk.virtualWrite(VIRTUAL_PIN_HEART_RATE, heartRate);
  Blynk.virtualWrite(VIRTUAL_PIN_SPO2, spo2);
  Blynk.virtualWrite(VIRTUAL_PIN_FALL_DETECTED, fallDetected ? 1 : 0);

  // Print to Serial for debugging
  Serial.print("Heart rate: ");
  Serial.print(heartRate);
  Serial.print(" bpm / SpO2: ");
  Serial.print(spo2);
  Serial.println("%");
}

void loop() {
  Blynk.run(); // Chạy Blynk

  sensors_event_t a, g, temp;
  mpu.getEvent(&a, &g, &temp);

  check_fall(a.acceleration.x, a.acceleration.y, a.acceleration.z,
             g.gyro.x, g.gyro.y, g.gyro.z);

  sendData();
  delay(100); // Đợi 100ms trước khi đọc tiếp
}
