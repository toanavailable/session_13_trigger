-- =====================================================
-- TẠO TRIGGER KIỂM TRA TÍNH HỢP LỆ CỦA NGÀY SINH
-- =====================================================

-- Bước 1: Chuẩn bị bảng dữ liệu
CREATE DATABASE IF NOT EXISTS trigger_practice CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE trigger_practice;

DROP TRIGGER IF EXISTS tg_check_birthday_before_insert;
DROP TABLE IF EXISTS student;

CREATE TABLE student (
    id       INT AUTO_INCREMENT PRIMARY KEY,
    name     VARCHAR(100) NOT NULL,
    birthday DATE         NOT NULL,
    phone    VARCHAR(15)
);

-- Bước 2, 3, 4: Tạo Trigger, ném lỗi bằng SIGNAL, bọc trong DELIMITER và BEGIN...END
DELIMITER //

CREATE TRIGGER tg_check_birthday_before_insert
BEFORE INSERT ON student
FOR EACH ROW
BEGIN
    -- Ngày sinh không được lớn hơn hoặc bằng ngày hiện tại
    IF NEW.birthday >= CURRENT_DATE() THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi hệ thống: Ngày sinh không hợp lệ, phải nhỏ hơn ngày hôm nay!';
    END IF;
END //

DELIMITER ;

-- Bước 5: Kiểm tra dữ liệu
-- Trường hợp thành công: Lê Thị C sinh ngày 01/01/2000
INSERT INTO student (name, birthday, phone)
VALUES ('Lê Thị C', '2000-01-01', '0912345678');

SELECT id, name, birthday, phone FROM student;
-- Kết quả: 1 dòng Lê Thị C đã vào bảng

-- Trường hợp lỗi [LỖI DỰ KIẾN]: Trần Văn B có ngày sinh đúng bằng hôm nay
-- Error Code: 1644. Lỗi hệ thống: Ngày sinh không hợp lệ, phải nhỏ hơn ngày hôm nay!
INSERT INTO student (name, birthday, phone)
VALUES ('Trần Văn B', CURRENT_DATE(), '0987654321');

-- Chạy lại sau lỗi để xác nhận Trần Văn B không được chèn:
-- SELECT id, name, birthday, phone FROM student;
