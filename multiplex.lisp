;;;; This file is part of cl-multiplex
;;;; Copyright 2018 Guillaume LE VAILLANT
;;;; Distributed under the GNU GPL v3 or later.
;;;; See the file LICENSE for terms of use and distribution.


(defpackage :multiplex
  (:nicknames :cl-multiplex)
  (:use :cl :octet-streams)
  (:export #:bad-channel-number
           #:frame-too-big
           #:make-multiplex-stream
           #:close-multiplex-stream
           #:with-multiplex-stream
           #:write-frame
           #:multiplex
           #:finish-multiplex-output
           #:clear-multiplex-input
           #:read-frame
           #:process-frame
           #:drop-frame
           #:demultiplex
           #:write-data
           #:read-data
           #:clear-channel-input
           #:get-channel-stream))

(in-package :multiplex)


(defstruct (multiplex-stream (:constructor %make-multiplex-stream))
  stream
  (buffer (make-array 1024 :element-type '(unsigned-byte 8))
          :type (simple-array (unsigned-byte 8) (*)))
  (frame nil :type list)
  inputs
  outputs)

(define-condition bad-channel-number (error)
  ((channel :initarg :channel :reader channel)
   (max-channel :initarg :max-channel :reader max-channel))
  (:report (lambda (condition stream)
             (format stream "Bad channel number: ~d (max ~d)"
                     (channel condition) (max-channel condition)))))

(define-condition frame-too-big (error)
  ((frame-length :initarg :frame-length :reader frame-length)
   (max-length :initarg :max-length :reader max-length))
  (:report (lambda (condition stream)
             (format stream "Frame too big: ~d bytes (max ~d bytes)"
                     (frame-length condition) (max-length condition)))))

(defun make-multiplex-stream (stream channels)
  "Return a multiplex stream. The data written to several channels
will be multiplexed before being written to STREAM. The data read from
STREAM will be demultiplexed and made available in the channels. The
number of channels to use is indicated by CHANNELS."
  (check-type channels (integer 1 *))
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

(defun write-frame (stream channel data &key (start 0) (end (length data)))
  "Make a frame for a CHANNEL with the bytes of DATA between START and END and
write it to a STREAM."
  (flet ((write-integer (n)
           (do* ((l (max 1 (ceiling (integer-length n) 7)) (1- l))
                 (x n (ash x -7)))
                ((zerop l) n)
             (write-byte (logior (logand x #x7f) (if (= l 1) 0 #x80)) stream))))
    (write-integer channel)
    (write-integer (- end start))
    (write-sequence data stream :start start :end end)))

(defun multiplex (multiplex-stream &optional (max-frame-size 1024))
  "Multiplex the data that was written to the channels of
MULTIPLEX-STREAM and write it to the underlying stream. The mutiplexed
frames written to the underlying stream contain at most
MAX-FRAME-SIZE bytes of user data."
  (let ((stream (multiplex-stream-stream multiplex-stream))
        (outputs (multiplex-stream-outputs multiplex-stream))
        (buffer (multiplex-stream-buffer multiplex-stream)))
    (when (< (length buffer) max-frame-size)
      (setf buffer (make-array max-frame-size :element-type '(unsigned-byte 8)))
      (setf (multiplex-stream-buffer multiplex-stream) buffer))
    (dotimes (channel (length outputs) t)
      (do ((length (read-sequence buffer (aref outputs channel))
                   (read-sequence buffer (aref outputs channel))))
          ((zerop length))
        (write-frame stream channel buffer :end length)))))

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

(defun read-frame (stream &key incomplete-frame max-frame-size buffer)
  "Try to read a frame from a STREAM. The first returned value is a list of
4 elements representing a frame (channel, total length of data, data, length of
data received so far). The second returned value is T if the frame is complete
and NIL otherwise. If INCOMPLETE-FRAME is specified (it must be an incomplete
frame returned by a previous call to READ-FRAME), the function tries to complete
it with new data from the STREAM. If MAX-FRAME-SIZE is a positive integer and
a frame bigger than MAX-FRAME-SIZE is detected, an error is signaled. If BUFFER
is specified (it must be an array of (UNSIGNED-BYTE 8)), the function tries to
use it instead of allocating a new work area."
  (let ((channel (car incomplete-frame))
        (length (cadr incomplete-frame))
        (data (or (caddr incomplete-frame)
                  buffer
                  (make-array (or max-frame-size 1024)
                              :element-type '(unsigned-byte 8))))
        (data-length (or (cadddr incomplete-frame) 0)))
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
      (handler-case
          (progn
            (unless channel
              (setf channel (read-integer)))
            (unless length
              (setf length (read-integer))
              (restart-case
                  (when (and (integerp max-frame-size) (> length max-frame-size))
                    (error 'frame-too-big :frame-length length :max-length max-frame-size))
                (process-frame ()
                  :report "Read the frame anyway.")
                (drop-frame ()
                  :report "Read the frame and discard it."
                  (do* ((r length (- r n))
                        (n (read-sequence data stream :end (min r (length data)))
                           (read-sequence data stream :end (min r (length data)))))
                       ((or (zerop r) (zerop n))))
                  (return-from read-frame (values (list nil nil data 0) nil))))))
        (end-of-file ()
          (return-from read-frame (values (list channel length data data-length)
                                          nil))))
      (when (> length (length data))
        (let ((new-buffer (make-array length :element-type '(unsigned-byte 8))))
          (replace new-buffer data :end2 data-length)
          (setf data new-buffer)))
      (let ((n (read-sequence data stream :start data-length :end length)))
        (values (list channel length data n)
                (= n length))))))

(defun demultiplex (multiplex-stream &optional max-frames max-frame-size)
  "Read data from the underlying stream of MULTIPLEX-STREAM and demultiplex the
frames. Return T if at least one frame was demultiplexed successfully, and NIL
otherwise. If MAX-FRAMES is a positive integer, at most MAX-FRAMES frames will
be demultiplexed. If MAX-FRAME-SIZE is a positive integer and a frame bigger
than MAX-FRAME-SIZE is detected, an error is signaled."
  (do ((stream (multiplex-stream-stream multiplex-stream))
       (inputs (multiplex-stream-inputs multiplex-stream))
       (incomplete-frame (multiplex-stream-frame multiplex-stream))
       (buffer nil)
       (at-least-one-frame-p nil)
       (n (when (and (integerp max-frames) (plusp max-frames))
            max-frames)
          (when n
            (1- n))))
      ((and n (zerop n)) at-least-one-frame-p)
    (multiple-value-bind (frame complete-frame-p)
        (read-frame stream
                    :incomplete-frame incomplete-frame
                    :max-frame-size max-frame-size
                    :buffer buffer)
      (unless complete-frame-p
        (setf (multiplex-stream-frame multiplex-stream) frame)
        (return-from demultiplex at-least-one-frame-p))
      (destructuring-bind (channel length data data-length)
          frame
        (declare (ignore data-length))
        (when (>= channel (length inputs))
          (error 'bad-channel-number :channel channel :max-channel (1- (length inputs))))
        (write-sequence data (aref inputs channel) :end length)
        (setf at-least-one-frame-p t)
        (setf buffer data)
        (when incomplete-frame
          (setf incomplete-frame nil)
          (setf (multiplex-stream-frame multiplex-stream) nil))))))

(defun write-data (data multiplex-stream channel &key (start 0) end)
  "Like WRITE-SEQUENCE for mutiplex streams. Write the byte of DATA
between START end END to a specific CHANNEL of MULTIPLEX-STREAM."
  (let ((outputs (multiplex-stream-outputs multiplex-stream)))
    (when (>= channel (length outputs))
      (error 'bad-channel-number :channel channel :max-channel (1- (length outputs))))
    (let ((output (aref outputs channel)))
      (write-sequence data output :start start :end end))))

(defun read-data (data multiplex-stream channel &key (start 0) end)
  "Like READ-SEQUENCE for multiplex streams. Fill DATA between START
and END with bytes read from a specific CHANNEL of MULTIPLEX-STREAM."
  (let ((inputs (multiplex-stream-inputs multiplex-stream)))
    (when (>= channel (length inputs))
      (error 'bad-channel-number :channel channel :max-channel (1- (length inputs))))
    (let ((input (aref inputs channel)))
      (read-sequence data input :start start :end end))))

(defun clear-channel-input (multiplex-stream channel)
  "Clear the input of a specific CHANNEL of MULTIPLEX-TREAM."
  (let ((inputs (multiplex-stream-inputs multiplex-stream)))
    (when (>= channel (length inputs))
      (error 'bad-channel-number :channel channel :max-channel (1- (length inputs))))
    (let ((input (aref inputs channel)))
      (clear-input input))))

(defun get-channel-stream (multiplex-stream channel)
  "Return a stream that can be used to read/write data from/to
a specific CHANNEL of MULTIPLEX-STREAM."
  (let ((inputs (multiplex-stream-inputs multiplex-stream))
        (outputs (multiplex-stream-outputs multiplex-stream)))
    (when (>= channel (length inputs))
      (error 'bad-channel-number :channel channel :max-channel (1- (length inputs))))
    (make-two-way-stream (aref inputs channel)
                         (aref outputs channel))))
