#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <BlynkSimpleEsp8266.h>
#include <PulseSensorPlayground.h>

// Blynk credentials
char auth[] = "uZ7KsOfKUp1bYydEEpYuvEOv_VmzObiB";
char ssid[] = "P906";
char pass[] = "213546987";

BlynkTimer timer;

// Sensor Addresses
#define MPU6050_ADDR 0x68
#define WINDOW_SIZE 200

Adafruit_MPU6050 mpu;

// Pulse Sensor config
#define PULSE_INPUT_PIN A0 // Chân analog ESP32
PulseSensorPlayground pulseSensor;

// Buffers for fall detection
float svm_buffer[WINDOW_SIZE];
float gyro_x_buffer[WINDOW_SIZE];
float gyro_y_buffer[WINDOW_SIZE];
float gyro_z_buffer[WINDOW_SIZE];
float svm_values[WINDOW_SIZE];
int buffer_index = 0;

// Variables to store the latest health data
int current_bpm = 0;
bool fallDetected = false;
unsigned long fallDetectedTime = 0;
bool fallDisplayActive = false;

// Virtual pins
#define VIRTUAL_PIN_HEART_RATE 1
#define VIRTUAL_PIN_FALL_DETECTED 2
#define VIRTUAL_PIN_PULSE_WAVE 3

void setup() {
    Serial.begin(115200);

    // Initialize Blynk
    Blynk.begin(auth, ssid, pass, "blynk.cloud", 80);

    // Initialize I2C
    Wire.begin();
    Wire.setClock(100000);

    // Initialize MPU6050
    Wire.beginTransmission(MPU6050_ADDR);
    if (Wire.endTransmission() == 0) {
        if (!mpu.begin()) {
            Serial.println("Failed to find MPU6050 chip");
            while (1) delay(10);
        }
        Serial.println("MPU6050 Found!");
        mpu.setAccelerometerRange(MPU6050_RANGE_16_G);
        mpu.setGyroRange(MPU6050_RANGE_2000_DEG);
        mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
    } else {
        Serial.println("MPU6050 not found! Check connections.");
    }

    // Initialize Pulse Sensor
    pulseSensor.analogInput(PULSE_INPUT_PIN);
    pulseSensor.setThreshold(550); // Có thể điều chỉnh ngưỡng này
    if (pulseSensor.begin()) {
        Serial.println("PulseSensor started!");
    } else {
        Serial.println("PulseSensor not found!");
    }

    // Initialize buffers
    for (int i = 0; i < WINDOW_SIZE; i++) {
        svm_buffer[i] = 0;
        gyro_x_buffer[i] = 0;
        gyro_y_buffer[i] = 0;
        gyro_z_buffer[i] = 0;
        svm_values[i] = 0;
    }

    timer.setInterval(200L, sendToBlynk);

    Serial.println("\nSystem initialized successfully!");
    Serial.println("--------------------------------");
}

void loop() {
    Blynk.run();
    timer.run();

    // Đọc dữ liệu MPU6050 và xử lý phát hiện ngã
    sensors_event_t a, g, temp;
    mpu.getEvent(&a, &g, &temp);
    bool prevFallDetected = fallDetected;
    check_fall(a.acceleration.x, a.acceleration.y, a.acceleration.z,
               g.gyro.x, g.gyro.y, g.gyro.z);

    // Nếu vừa phát hiện ngã
    if (!prevFallDetected && fallDetected) {
        fallDisplayActive = true;
        fallDetectedTime = millis();
    }
    // Nếu đang hiển thị ngã và đã đủ 5s thì cho phép cập nhật lại trạng thái
    if (fallDisplayActive && (millis() - fallDetectedTime >= 5000)) {
        fallDisplayActive = false;
        fallDetected = false;
    }

    // Đọc nhịp tim từ Pulse Sensor
    int bpm = pulseSensor.getBeatsPerMinute();
    bool beatDetected = pulseSensor.sawStartOfBeat();

    if (beatDetected) {
        Serial.print("Beat! BPM: ");
        Serial.println(bpm);
    }

    if (bpm > 0) {
        current_bpm = bpm;
    }
}

void sendToBlynk() {
    Blynk.virtualWrite(VIRTUAL_PIN_HEART_RATE, current_bpm);
    // Nếu đang hiển thị ngã thì gửi 1, còn lại gửi 0
    Blynk.virtualWrite(VIRTUAL_PIN_FALL_DETECTED, fallDisplayActive ? 1 : 0);

    int signal = analogRead(PULSE_INPUT_PIN);
    Blynk.virtualWrite(VIRTUAL_PIN_PULSE_WAVE, signal);

    Serial.println("\n--- Gửi lên Blynk ---");
    Serial.print("Heart rate: "); Serial.println(current_bpm);
    Serial.print("Fall detected: "); Serial.println(fallDisplayActive ? "YES" : "NO");
    Serial.print("Pulse signal: "); Serial.println(signal);
    Serial.println("---------------------");
}

void check_fall(float ax, float ay, float az, float gx, float gy, float gz) {
    float svm = sqrt(ax * ax + ay * ay + az * az) / 9.81;
    float abs_gx = abs(gx);
    float abs_gy = abs(gy);
    float abs_gz = abs(gz);

    svm_buffer[buffer_index] = svm;
    gyro_x_buffer[buffer_index] = abs_gx;
    gyro_y_buffer[buffer_index] = abs_gy;
    gyro_z_buffer[buffer_index] = abs_gz;
    svm_values[buffer_index] = svm;
    buffer_index = (buffer_index + 1) % WINDOW_SIZE;

    float max_svm = svm_buffer[0];
    float max_gyro_x = gyro_x_buffer[0];
    float max_gyro_y = gyro_y_buffer[0];
    float max_gyro_z = gyro_z_buffer[0];
    float svm_sum = svm_values[0];
    float svm_sq_sum = svm_values[0] * svm_values[0];
    float svm_change = 0;
    for (int i = 1; i < WINDOW_SIZE; i++) {
        if (svm_buffer[i] > max_svm) max_svm = svm_buffer[i];
        if (gyro_x_buffer[i] > max_gyro_x) max_gyro_x = gyro_x_buffer[i];
        if (gyro_y_buffer[i] > max_gyro_y) max_gyro_y = gyro_y_buffer[i];
        if (gyro_z_buffer[i] > max_gyro_z) max_gyro_z = gyro_z_buffer[i];
        svm_sum += svm_values[i];
        svm_sq_sum += svm_values[i] * svm_values[i];
        svm_change += abs(svm_values[i] - svm_values[i-1]);
    }
    float svm_mean = svm_sum / WINDOW_SIZE;
    float svm_std = sqrt(svm_sq_sum / WINDOW_SIZE - svm_mean * svm_mean);

    // Quy tắc cây quyết định
    if (max_svm <= 2.64) {
        if (max_gyro_z <= 198.37) {
            if (max_gyro_y <= 253.39) {
                if (max_gyro_x <= 324.59) {
                    fallDetected = false;
                } else {
                    fallDetected = false;
                }
            } else {
                if (max_gyro_x <= 128.35) {
                    fallDetected = false;
                } else {
                    fallDetected = true;
                }
            }
        } else {
            fallDetected = true;
        }
    } else {
        if (max_gyro_y <= 144.14) {
            if (max_svm <= 5.56) {
                if (svm_std <= 0.31) {
                    fallDetected = false;
                } else {
                    fallDetected = false;
                }
            } else {
                if (svm_change <= 43.16) {
                    fallDetected = false;
                } else {
                    fallDetected = true;
                }
            }
        } else {
            if (svm_change <= 156.40) {
                if (max_gyro_y <= 240.28) {
                    fallDetected = true;
                } else {
                    fallDetected = true;
                }
            } else {
                if (max_svm <= 9.28) {
                    fallDetected = false;
                } else {
                    fallDetected = true;
                }
            }
        }
    }
}
