;;;; This file is part of cl-multiplex
;;;; Copyright 2018 Guillaume LE VAILLANT
;;;; Distributed under the GNU GPL v3 or later.
;;;; See the file LICENSE for terms of use and distribution.


(defpackage :multiplex
  (:nicknames :cl-multiplex)
  (:use :cl :octet-streams)
  (:export #:make-multiplex-stream
           #:close-multiplex-stream
           #:with-multiplex-stream
           #:multiplex
           #:finish-multiplex-output
           #:clear-multiplex-input
           #:demultiplex
           #:write-data
           #:read-data
           #:clear-channel-input
           #:get-channel-stream))

(in-package :multiplex)


(defstruct (multiplex-stream (:constructor %make-multiplex-stream))
  stream
  (data (make-array 128 :element-type '(unsigned-byte 8))
   :type (simple-array (unsigned-byte 8) (*)))
  (data-length 0 :type (mod #.array-dimension-limit))
  (current-frame-channel nil :type (or null unsigned-byte))
  (current-frame-length nil :type (or null unsigned-byte))
  inputs
  outputs)

(defun make-multiplex-stream (stream channels)
  "Return a multiplex stream. The data written to several channels
will be multiplexed before being written to STREAM. The data read from
STREAM will be demultiplexed and made available in the channels. The
number of channels to use is indicated by CHANNELS."
  (assert (plusp channels))
  (let ((inputs (make-array channels))
        (outputs (make-array channels)))
    (dotimes (channel channels)
      (setf (aref inputs channel) (make-octet-pipe))
      (setf (aref outputs channel) (make-octet-pipe)))
    (%make-multiplex-stream :stream stream
                            :inputs inputs
                            :outputs outputs)))

(defun close-multiplex-stream (multiplex-stream)
  "Close all the channels of MULTIPLEX-STREAM."
  (let ((inputs (multiplex-stream-inputs multiplex-stream))
        (outputs (multiplex-stream-outputs multiplex-stream)))
    (dotimes (channel (length inputs))
      (close (aref inputs channel))
      (close (aref outputs channel)))))

(defmacro with-multiplex-stream ((var stream channels) &body body)
  "Within BODY, VAR is bound to a multiplex stream defined by STREAM
and CHANNELS. The result of the last form of BODY is returned."
  `(let ((,var (make-multiplex-stream ,stream ,channels)))
     (unwind-protect
          ,@body
       (close-multiplex-stream ,var))))

(defun multiplex (multiplex-stream &optional (max-frame-size 1024))
  "Multiplex the data that was written to the channels of
MULTIPLEX-STREAM and write it to the underlying stream. The mutiplexed
frames written to the underlying stream contain at most
MAX-FRAME-SIZE bytes of user data."
  (let ((stream (multiplex-stream-stream multiplex-stream))
        (outputs (multiplex-stream-outputs multiplex-stream))
        (buffer (make-array max-frame-size :element-type '(unsigned-byte 8))))
    (flet ((write-integer (n)
             (do* ((l (max 1 (ceiling (integer-length n) 7)) (1- l))
                   (x n (ash x -7)))
                  ((zerop l) n)
               (write-byte (logior (logand x #x7f) (if (= l 1) 0 #x80)) stream))))
      (dotimes (channel (length outputs) t)
        (do ((length (read-sequence buffer (aref outputs channel))
                     (read-sequence buffer (aref outputs channel))))
            ((zerop length))
          (write-integer channel)
          (write-integer length)
          (write-sequence buffer stream :end length))))))

(defun finish-multiplex-output (multiplex-stream)
  "Multiplex the data that was written to the channels of
MULTIPLEX-STREAM and return when everything has been written
successfully to the underlying stream."
  (multiplex multiplex-stream)
  (finish-output (multiplex-stream-stream multiplex-stream)))

(defun clear-multiplex-input (multiplex-stream)
  "Clear the input of all the channels of MULTIPLEX-TREAM."
  (let ((inputs (multiplex-stream-inputs multiplex-stream)))
    (dotimes (channel (length inputs))
      (clear-input (aref inputs channel)))))

(defun demultiplex-1 (multiplex-stream)
  "Read data from the underlying stream of MULTIPLEX-STREAM and
demultiplex one frame. Return T if a frame was demultiplexed
successfully, and NIL otherwise."
  (with-slots (stream
               data
               data-length
               (channel current-frame-channel)
               (length current-frame-length)
               inputs)
      multiplex-stream
    (flet ((read-integer ()
             (loop
               (let ((b (read-byte stream)))
                 (when (= data-length (length data))
                   (let ((new-buffer (make-array (* 2 (length data))
                                                 :element-type '(unsigned-byte 8))))
                     (replace new-buffer data :end2 data-length)
                     (setf data new-buffer)))
                 (setf (aref data data-length) b)
                 (incf data-length)
                 (when (zerop (logand b #x80))
                   (do* ((i 0 (1+ i))
                         (j 0 (+ j 7))
                         (b (aref data i) (aref data i))
                         (n (logand b #x7f) (+ n (ash (logand b #x7f) j))))
                        ((= i (1- data-length))
                         (progn
                           (setf data-length 0)
                           (return-from read-integer n)))))))))
      (unless channel
        (setf channel (read-integer)))
      (unless length
        (setf length (read-integer)))
      (when (> length (length data))
        (setf data (make-array length :element-type '(unsigned-byte 8))))
      (let ((input (aref inputs channel))
            (n (read-sequence data stream :start data-length :end length)))
        (if (= n length)
            (progn
              (write-sequence data input :end length)
              (setf data-length 0)
              (setf channel nil)
              (setf length nil)
              t)
            (progn
              (setf data-length n)
              nil))))))

(defun demultiplex (multiplex-stream &optional max-frames)
  "Read data from the underlying stream of MULTIPLEX-STREAM and
demultiplex the frames. Return T if at least one frame was
demultiplexed successfully, and NIL otherwise. If MAX-FRAMES is
a positive integer, at most MAX-FRAMES frames will be demultiplexed."
  (let ((at-least-one-frame-p nil))
    (handler-case
        (do ((frame-p t)
             (n (when (and (integerp max-frames) (plusp max-frames))
                  max-frames)))
            ((or (null frame-p) (and n (zerop n))) at-least-one-frame-p)
          (setf frame-p (demultiplex-1 multiplex-stream))
          (when frame-p
            (when n
              (decf n))
            (unless at-least-one-frame-p
              (setf at-least-one-frame-p t))))
      (end-of-file (err)
        (or at-least-one-frame-p (error err))))))

(defun write-data (data multiplex-stream channel &key (start 0) end)
  "Like WRITE-SEQUENCE for mutiplex streams. Write the byte of DATA
between START end END to a specific CHANNEL of MULTIPLEX-STREAM."
  (let ((output (aref (multiplex-stream-outputs multiplex-stream) channel)))
    (write-sequence data output :start start :end end)))

(defun read-data (data multiplex-stream channel &key (start 0) end)
  "Like READ-SEQUENCE for multiplex streams. Fill DATA between START
and END with bytes read from a specific CHANNEL of MULTIPLEX-STREAM."
  (let ((input (aref (multiplex-stream-inputs multiplex-stream) channel)))
    (read-sequence data input :start start :end end)))

(defun clear-channel-input (multiplex-stream channel)
  "Clear the input of a specific CHANNEL of MULTIPLEX-TREAM."
  (let ((input (aref (multiplex-stream-inputs multiplex-stream) channel)))
    (clear-input input)))

(defun get-channel-stream (multiplex-stream channel)
  "Return a stream that can be used to read/write data from/to
a specific CHANNEL of MULTIPLEX-STREAM."
  (make-two-way-stream (aref (multiplex-stream-inputs multiplex-stream) channel)
                       (aref (multiplex-stream-outputs multiplex-stream) channel)))
