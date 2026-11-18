-- =====================================================
-- SỰ CỐ DỜI LỊCH KHÁM VỀ QUÁ KHỨ - Trigger PreventPastAppointments
-- =====================================================

-- 0. Dữ liệu mẫu (ngày khám tính theo NOW() để chạy lúc nào cũng đúng)
CREATE DATABASE IF NOT EXISTS rikkei_clinic_trigger CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE rikkei_clinic_trigger;

DROP TRIGGER IF EXISTS PreventPastAppointments;
DROP TABLE IF EXISTS Appointments;

CREATE TABLE Appointments (
    appointment_id   INT PRIMARY KEY,
    patient_name     VARCHAR(100) NOT NULL,
    doctor_name      VARCHAR(100) NOT NULL,
    appointment_date DATETIME     NOT NULL,
    status           VARCHAR(20)  NOT NULL DEFAULT 'Pending'   -- Pending / Completed / Cancelled
);

INSERT INTO Appointments (appointment_id, patient_name, doctor_name, appointment_date, status) VALUES
    (101, 'Nguyen Van A', 'BS. Tran Minh', DATE_SUB(NOW(), INTERVAL 2 HOUR), 'Pending'),
    (102, 'Tran Thi B',   'BS. Tran Minh', DATE_ADD(NOW(), INTERVAL 3 DAY),  'Pending'),
    (103, 'Le Hoang C',   'BS. Pham Lan',  DATE_SUB(NOW(), INTERVAL 10 DAY), 'Completed'),
    (104, 'Pham Thu D',   'BS. Pham Lan',  DATE_ADD(NOW(), INTERVAL 7 DAY),  'Pending');

-- =====================================================
-- MÃ NGUỒN CŨ (đang chạy ngầm trên bảng Appointments)
-- =====================================================
DELIMITER //

CREATE TRIGGER PreventPastAppointments
BEFORE UPDATE ON Appointments
FOR EACH ROW
BEGIN
    -- Lỗi logic: đang lấy ngày cũ ra so sánh với hiện tại thay vì kiểm tra ngày mới
    IF OLD.appointment_date < NOW() THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Không thể đặt lịch khám vào thời điểm trong quá khứ!';
    END IF;
END //

DELIMITER ;

-- =====================================================
-- PHẦN A - TÁI HIỆN LỖI
-- =====================================================
-- Tiếp tân bấm nhầm tháng 1 năm ngoái khi dời lịch cho bệnh nhân 104
UPDATE Appointments
SET appointment_date = CONCAT(YEAR(NOW()) - 1, '-01-15 09:00:00')
WHERE appointment_id = 104;

SELECT appointment_id, patient_name, appointment_date
FROM Appointments
WHERE appointment_id = 104;
-- Kết quả: cập nhật thành công, lịch 104 nằm ở tháng 1 năm ngoái -> lọt khỏi danh sách chờ

-- Lỗi thứ hai của mã cũ (chạy riêng để quan sát): lịch 101 vừa diễn ra 2 tiếng trước,
-- bác sĩ muốn chốt "Completed" nhưng bị chặn oan vì OLD.appointment_date < NOW()
-- UPDATE Appointments SET status = 'Completed' WHERE appointment_id = 101;

-- Khôi phục lịch 104 về ngày hợp lệ trước khi sửa trigger
DROP TRIGGER IF EXISTS PreventPastAppointments;
UPDATE Appointments
SET appointment_date = DATE_ADD(NOW(), INTERVAL 7 DAY)
WHERE appointment_id = 104;

-- =====================================================
-- PHẦN B - SỬA CHỮA MÃ NGUỒN
-- =====================================================
DROP TRIGGER IF EXISTS PreventPastAppointments;

DELIMITER //

CREATE TRIGGER PreventPastAppointments
BEFORE UPDATE ON Appointments
FOR EACH ROW
BEGIN
    -- Chỉ kiểm tra khi ngày khám thật sự bị đổi, và kiểm tra trên giá trị MỚI
    IF NEW.appointment_date <> OLD.appointment_date
       AND NEW.appointment_date < NOW() THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Không thể đặt lịch khám vào thời điểm trong quá khứ!';
    END IF;
END //

DELIMITER ;

-- =====================================================
-- KIỂM THỬ
-- =====================================================
-- Test 1: dời lịch 104 sang một ngày trong tương lai -> thành công
UPDATE Appointments
SET appointment_date = DATE_ADD(NOW(), INTERVAL 14 DAY)
WHERE appointment_id = 104;

-- Test 2: chốt trạng thái lịch 101 (ngày khám đã qua, không đổi ngày) -> thành công
UPDATE Appointments
SET status = 'Completed'
WHERE appointment_id = 101;

SELECT appointment_id, patient_name, appointment_date, status
FROM Appointments
ORDER BY appointment_id;

-- Test 3 [LỖI DỰ KIẾN]: dời lịch 104 về tháng 1 năm ngoái -> bị chặn
-- Error Code: 1644. Lỗi: Không thể đặt lịch khám vào thời điểm trong quá khứ!
UPDATE Appointments
SET appointment_date = CONCAT(YEAR(NOW()) - 1, '-01-15 09:00:00')
WHERE appointment_id = 104;
