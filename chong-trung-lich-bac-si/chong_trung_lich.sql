-- =====================================================
-- CHỐNG TRÙNG LỊCH BÁC SĨ (DOUBLE-BOOKING)
-- =====================================================

-- 0. Dữ liệu mẫu
CREATE DATABASE IF NOT EXISTS rikkei_clinic_trigger CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE rikkei_clinic_trigger;

DROP TRIGGER IF EXISTS PreventPastAppointments;   -- trigger của các bài trước (nếu có) trên cùng bảng
DROP TRIGGER IF EXISTS PreventStatusRevert;
DROP TRIGGER IF EXISTS trg_appointments_before_insert_double_booking;
DROP TRIGGER IF EXISTS trg_appointments_before_update_double_booking;
DROP TABLE IF EXISTS Appointments;
DROP TABLE IF EXISTS Doctors;

CREATE TABLE Doctors (
    doctor_id   INT PRIMARY KEY,
    doctor_name VARCHAR(100) NOT NULL
);

CREATE TABLE Appointments (
    appointment_id   INT AUTO_INCREMENT PRIMARY KEY,
    doctor_id        INT          NOT NULL,
    patient_name     VARCHAR(100) NOT NULL,
    appointment_date DATETIME     NOT NULL,                  -- giờ bắt đầu ca khám
    status           VARCHAR(20)  NOT NULL DEFAULT 'Pending', -- Pending / Completed / Cancelled
    CONSTRAINT fk_appt_doctor FOREIGN KEY (doctor_id) REFERENCES Doctors (doctor_id),
    INDEX idx_appt_doctor_date (doctor_id, appointment_date)   -- phục vụ truy vấn kiểm tra trùng lịch
);

INSERT INTO Doctors (doctor_id, doctor_name) VALUES
    (1, 'BS. Tran Minh'),
    (2, 'BS. Pham Lan');

INSERT INTO Appointments (doctor_id, patient_name, appointment_date, status) VALUES
    (1, 'Nguyen Van A', '2026-12-01 08:00:00', 'Pending'),     -- id 1
    (1, 'Tran Thi B',   '2026-12-01 09:00:00', 'Cancelled'),   -- id 2: ca đã hủy -> giờ trống
    (2, 'Le Hoang C',   '2026-12-01 08:00:00', 'Pending');     -- id 3: khác bác sĩ

-- =====================================================
-- 1. TRIGGER CHO THAO TÁC THÊM LỊCH MỚI (INSERT)
-- =====================================================
DELIMITER //

CREATE TRIGGER trg_appointments_before_insert_double_booking
BEFORE INSERT ON Appointments
FOR EACH ROW
BEGIN
    -- Lịch mới ở trạng thái Cancelled thì không chiếm giờ, không cần kiểm tra
    IF NEW.status <> 'Cancelled' AND EXISTS (
        SELECT 1
        FROM Appointments AS a
        WHERE a.doctor_id        = NEW.doctor_id
          AND a.appointment_date = NEW.appointment_date
          AND a.status          <> 'Cancelled'            -- Ngoại lệ 1: ca đã hủy là giờ trống
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Bác sĩ đã có lịch hẹn vào khung giờ này';
    END IF;
END //

-- =====================================================
-- 2. TRIGGER CHO THAO TÁC DỜI / CẬP NHẬT LỊCH (UPDATE)
-- =====================================================
CREATE TRIGGER trg_appointments_before_update_double_booking
BEFORE UPDATE ON Appointments
FOR EACH ROW
BEGIN
    IF NEW.status <> 'Cancelled' AND EXISTS (
        SELECT 1
        FROM Appointments AS a
        WHERE a.doctor_id        = NEW.doctor_id
          AND a.appointment_date = NEW.appointment_date
          AND a.status          <> 'Cancelled'            -- Ngoại lệ 1: ca đã hủy là giờ trống
          AND a.appointment_id  <> NEW.appointment_id     -- Ngoại lệ 2: không so với chính nó
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Bác sĩ đã có lịch hẹn vào khung giờ này';
    END IF;
END //

DELIMITER ;

-- =====================================================
-- 3. KIỂM THỬ
-- =====================================================
-- Kịch bản 1: lịch mới vào khung giờ hoàn toàn trống (BS 1, 10:00) -> thành công
INSERT INTO Appointments (doctor_id, patient_name, appointment_date)
VALUES (1, 'Pham Thu D', '2026-12-01 10:00:00');

-- Kịch bản 3: lịch mới vào khung giờ đang có ca 'Cancelled' (BS 1, 09:00) -> thành công
INSERT INTO Appointments (doctor_id, patient_name, appointment_date)
VALUES (1, 'Vo Thanh E', '2026-12-01 09:00:00');

-- Kịch bản 4: chốt ca id 1 từ 'Pending' sang 'Completed' -> thành công (vượt qua ngoại lệ 2)
UPDATE Appointments SET status = 'Completed' WHERE appointment_id = 1;

SELECT appointment_id, doctor_id, patient_name, appointment_date, status
FROM Appointments
ORDER BY doctor_id, appointment_date, appointment_id;

-- Kịch bản 2 [LỖI DỰ KIẾN]: lịch mới vào khung giờ đang có ca 'Pending' (BS 1, 10:00) -> bị chặn
-- Error Code: 1644. Lỗi: Bác sĩ đã có lịch hẹn vào khung giờ này
INSERT INTO Appointments (doctor_id, patient_name, appointment_date)
VALUES (1, 'Hoang Van F', '2026-12-01 10:00:00');

-- Kịch bản bổ sung [LỖI DỰ KIẾN] (chạy riêng): dời ca id 3 sang BS 1 lúc 08:00 -> bị chặn
-- UPDATE Appointments SET doctor_id = 1 WHERE appointment_id = 3;
