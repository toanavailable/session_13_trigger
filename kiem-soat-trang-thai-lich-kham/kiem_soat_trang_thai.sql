-- =====================================================
-- KIỂM SOÁT TRẠNG THÁI LỊCH KHÁM - Trigger PreventStatusRevert
-- =====================================================

-- 0. Dữ liệu mẫu
CREATE DATABASE IF NOT EXISTS rikkei_clinic_trigger CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE rikkei_clinic_trigger;

DROP TRIGGER IF EXISTS PreventPastAppointments;   -- trigger của bài trước (nếu có) trên cùng bảng
DROP TRIGGER IF EXISTS PreventStatusRevert;
DROP TABLE IF EXISTS Appointments;

CREATE TABLE Appointments (
    appointment_id   INT PRIMARY KEY,
    patient_name     VARCHAR(100) NOT NULL,
    appointment_date DATETIME     NOT NULL,
    status           VARCHAR(20)  NOT NULL DEFAULT 'Pending',   -- Pending / Completed / Cancelled
    note             VARCHAR(255)
);

INSERT INTO Appointments (appointment_id, patient_name, appointment_date, status, note) VALUES
    (103, 'Le Hoang C',   '2026-11-10 08:00:00', 'Completed', 'Đã khám, đã thu tiền'),
    (104, 'Pham Thu D',   '2026-11-19 09:00:00', 'Pending',   NULL),
    (105, 'Vo Thanh E',   '2026-11-25 10:30:00', 'Pending',   NULL);

-- =====================================================
-- MÃ NGUỒN CŨ
-- =====================================================
DELIMITER //

CREATE TRIGGER PreventStatusRevert
BEFORE UPDATE ON Appointments
FOR EACH ROW
BEGIN
    -- Lỗi logic: dùng NEW thay vì OLD khiến toàn bộ hệ thống bị "tê liệt"
    IF NEW.status = 'Completed' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Không được phép thao tác trên lịch khám này!';
    END IF;
END //

DELIMITER ;

-- =====================================================
-- PHẦN A - TÁI HIỆN LỖI
-- =====================================================
-- Chạy riêng lệnh dưới đây để quan sát lỗi (để dạng comment vì lỗi sẽ dừng script):
-- UPDATE Appointments SET status = 'Completed' WHERE appointment_id = 104;
-- Kết quả: Error Code: 1644. Lỗi: Không được phép thao tác trên lịch khám này!
-- -> Bác sĩ không thể chốt ca khám hợp lệ Pending -> Completed.

-- =====================================================
-- PHẦN B - SỬA CHỮA MÃ NGUỒN
-- =====================================================
DROP TRIGGER IF EXISTS PreventStatusRevert;

DELIMITER //

CREATE TRIGGER PreventStatusRevert
BEFORE UPDATE ON Appointments
FOR EACH ROW
BEGIN
    -- Kiểm tra trạng thái ĐANG LƯU trong bảng: lịch đã Completed là "đóng sổ"
    IF OLD.status = 'Completed' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Lịch khám đã hoàn thành (đóng sổ), không được phép thay đổi!';
    END IF;
END //

DELIMITER ;

-- =====================================================
-- KIỂM THỬ
-- =====================================================
-- Test 1: chốt lịch 104 từ Pending sang Completed -> thành công
UPDATE Appointments SET status = 'Completed' WHERE appointment_id = 104;

-- Test 2: hủy lịch 105 đang Pending -> thành công
UPDATE Appointments SET status = 'Cancelled' WHERE appointment_id = 105;

SELECT appointment_id, patient_name, status
FROM Appointments
ORDER BY appointment_id;

-- Test 3 [LỖI DỰ KIẾN]: kéo lịch 103 đã Completed về Pending -> bị chặn
-- Error Code: 1644. Lỗi: Lịch khám đã hoàn thành (đóng sổ), không được phép thay đổi!
UPDATE Appointments SET status = 'Pending' WHERE appointment_id = 103;
