;;; sexpr_ir_sbcl.lisp - Common Lisp port of sexpr_ir_poc.py
;;;
;;; Minimal executable S-expression IR: parser (native SBCL reader) +
;;; interpreter + C generator.
;;; Reference functions: sqr (NSGradient.m:346), euclidian_distance (:351),
;;; centerSizeInRect (NSSplitView.m:985).

(defpackage :ir-poc
  (:use :cl)
  (:export :main :repl))
(in-package :ir-poc)

(defparameter *ir-source*
  "(:function sqr :params (:v CGFloat) :ret CGFloat
  :body (* :v :v))

(:function euclidian_distance
  :params (:ax CGFloat :ay CGFloat :bx CGFloat :by CGFloat)
  :ret CGFloat
  :body (sqrt (+ (:call sqr (- :ax :bx)) (:call sqr (- :ay :by)))))

(:function centerSizeInRect
  :params (:innerSize NSSize :inRect NSRect)
  :ret NSPoint
  :body (:call point
    (+ (:field :inRect :x)
       (max (- (:call midx :inRect) (/ (:field :innerSize :width) 2.0)) 0))
    (+ (:field :inRect :y)
       (max (- (:call midy :inRect) (/ (:field :innerSize :height) 2.0)) 0))))

(:function crc32_step :params (:crc UInt32 :b UInt32) :ret UInt32
  :body (:let (:crc2 (xor :crc :b))
    (:loop 8
      (:set :crc2 (:if (and :crc2 1)
                    (xor (shr :crc2 1) 3988292384)
                    (shr :crc2 1))))))

(:function crc32_full :params (:b1 UInt32 :b2 UInt32 :b3 UInt32 :b4 UInt32 :b5 UInt32 :b6 UInt32 :b7 UInt32 :b8 UInt32 :b9 UInt32) :ret UInt32
  :body (xor (:call crc32_step (:call crc32_step (:call crc32_step (:call crc32_step (:call crc32_step (:call crc32_step (:call crc32_step (:call crc32_step (:call crc32_step 4294967295 :b1) :b2) :b3) :b4) :b5) :b6) :b7) :b8) :b9) 4294967295))")

;; parser

(defun parse-ir (src)
  (let ((*readtable* (copy-readtable nil)))
    (setf (readtable-case *readtable*) :preserve)
    (with-input-from-string (s src)
      (loop for form = (read s nil :eof)
            until (eq form :eof)
            collect form))))

(defun is-keyword (x name)
  (and (keywordp x)
       (string= (string-upcase (symbol-name x)) name)))

(defun function-form-p (form)
  (and (consp form) (is-keyword (car form) "FUNCTION")))

(defun form-parts (form)
  (let ((name (symbol-name (cadr form)))
        (params nil) (ret nil) (body nil)
        (n (length form)))
    (do ((i 2 (+ i 2)))
        ((>= i n))
      (let ((k (nth i form)) (v (nth (1+ i) form)))
        (cond
          ((is-keyword k "PARAMS") (setf params v))
          ((is-keyword k "RET")    (setf ret v))
          ((is-keyword k "BODY")   (setf body v))
          (t (error "unknown key in form: ~S" k)))))
    (values name params ret body)))

(defun plist-evens (pl)
  (loop for j from 0 below (length pl) by 2 collect (nth j pl)))

(defun getf-plist (plist key-name)
  (loop for (k v) on plist by #'cddr
        when (string= (string-upcase (symbol-name k)) key-name)
          return v))

;; interpreter

(defparameter *fn-table* (make-hash-table :test 'equal))

(defun register-fns (tree)
  (dolist (form tree)
    (when (function-form-p form)
      (multiple-value-bind (name params ret body) (form-parts form)
        (setf (gethash (string-upcase name) *fn-table*)
              (list params ret body))))))

(defun ffloat (x) (float x 1.0d0))

(defun ir-int (x) (if (integerp x) x (truncate (ffloat x))))

(defun lookup-env (env sym)
  (gethash (string-upcase (symbol-name sym)) env))

(defun ir-add (vals) (loop for v in vals sum (ffloat v)))

(defun ir-sub (vals)
  (if (null (rest vals))
      (- (ffloat (first vals)))
      (loop for v in (rest vals)
            with r = (ffloat (first vals))
            do (decf r (ffloat v))
            finally (return r))))

(defun ir-mul (vals)
  (loop for v in vals
        with r = 1.0d0
        do (setf r (* r (ffloat v)))
        finally (return r)))

(defun ir-div (vals) (/ (ffloat (first vals)) (ffloat (second vals))))

(defun ir-point (vals) (list (ffloat (first vals)) (ffloat (second vals))))

(defun ir-midx (vals)
  (let ((r (first vals)))
    (+ (ffloat (getf-plist r "X"))
       (/ (ffloat (getf-plist r "WIDTH")) 2.0d0))))

(defun ir-midy (vals)
  (let ((r (first vals)))
    (+ (ffloat (getf-plist r "Y"))
       (/ (ffloat (getf-plist r "HEIGHT")) 2.0d0))))

(defun ir-cmp (op vals)
  (let ((a (ffloat (first vals))) (b (ffloat (second vals))))
    (cond ((string= op "<") (< a b))
          ((string= op ">") (> a b))
          ((string= op "==") (= a b))
          (t (error "bad comparison op: ~A" op)))))

(defun apply-ir-op (op vals)
  (cond
    ((string= op "+") (ir-add vals))
    ((string= op "-") (ir-sub vals))
    ((string= op "*") (ir-mul vals))
    ((string= op "/") (ir-div vals))
    ((string= op "MAX") (reduce #'max vals :key #'ffloat))
    ((string= op "MIN") (reduce #'min vals :key #'ffloat))
    ((string= op "SQRT") (sqrt (ffloat (first vals))))
    ((string= op "ABS") (abs (ffloat (first vals))))
    ((string= op "XOR") (logxor (ir-int (first vals)) (ir-int (second vals))))
    ((string= op "AND") (logand (ir-int (first vals)) (ir-int (second vals))))
    ((string= op "SHL") (ash (ir-int (first vals)) (ir-int (second vals))))
    ((string= op "SHR") (ash (ir-int (first vals)) (- (ir-int (second vals)))))
    ((string= op "POINT") (ir-point vals))
    ((string= op "MIDX") (ir-midx vals))
    ((string= op "MIDY") (ir-midy vals))
    ((member op '("<" ">" "==") :test #'string=) (ir-cmp op vals))
    (t (error "unsupported op in IR: ~A" op))))

(defun eval-node (node env)
  (typecase node
    (number node)
    (cons (eval-form node env))
    (symbol (lookup-env env node))
    (otherwise node)))

(defun eval-form (form env)
  (let ((op (string-upcase (symbol-name (car form)))))
    (cond
      ((string= op "IF")
       (if (/= (eval-node (second form) env) 0)
           (eval-node (third form) env)
           (eval-node (fourth form) env)))
      ((string= op "FIELD")
       (getf-plist (eval-node (second form) env)
                   (string-upcase (symbol-name (third form)))))
      ((string= op "CALL")
       (let* ((cname (string-upcase (symbol-name (second form))))
              (args (mapcar (lambda (a) (eval-node a env)) (cddr form))))
         (cond
           ((string= cname "POINT") (ir-point args))
           ((gethash cname *fn-table*) (call-fn cname args))
           (t (apply-ir-op cname args)))))
      ((string= op "LET")
       (let ((b (second form)))
         (loop for j from 0 below (length b) by 2
               do (setf (gethash (string-upcase (symbol-name (nth j b))) env)
                        (eval-node (nth (1+ j) b) env)))
         (loop for s in (cddr form)
               with result = nil
               do (setf result (eval-node s env))
               finally (return result))))
      ((string= op "LOOP")
       (loop for i from 1 to (truncate (second form))
             with result = nil
             do (loop for s in (cddr form)
                      do (setf result (eval-node s env)))
             finally (return result)))
      ((string= op "SET")
       (setf (gethash (string-upcase (symbol-name (second form))) env)
             (eval-node (third form) env)))
      (t (apply-ir-op op
                      (mapcar (lambda (a) (eval-node a env)) (cdr form)))))))

(defun eval-body (body env)
  (if (and (consp body) (symbolp (car body)))
      (eval-node body env)
      (loop for expr in body
            with result = nil
            do (setf result (eval-node expr env))
            finally (return result))))

(defun call-fn (name argv)
  (let* ((fn (gethash (string-upcase name) *fn-table*)))
    (unless fn (error "no IR function named ~S" name))
    (let* ((params (first fn))
           (body (third fn))
           (env (make-hash-table :test 'equal)))
      (loop for p in (plist-evens params) for a in argv
            do (setf (gethash (string-upcase (symbol-name p)) env) a))
      (eval-body body env))))

;; test corpus

(defparameter *tolerance* 1.0d-9)

(defparameter *tests*
  '(("sqr"
     (((2.0d0) 4.0d0) ((-3.0d0) 9.0d0) ((2.5d0) 6.25d0)))
    ("euclidian_distance"
     (((0.0d0 0.0d0 3.0d0 4.0d0) 5.0d0)
      ((0.0d0 0.0d0 1.0d0 1.0d0) #.(sqrt 2.0d0))
      ((1.0d0 1.0d0 2.0d0 2.0d0) #.(sqrt 2.0d0))
      ((1.5d0 2.5d0 4.5d0 6.5d0) 5.0d0)
      ((0.0d0 0.0d0 0.0d0 0.0d0) 0.0d0)))
    ("centerSizeInRect"
     ((((:width 8.0d0 :height 6.0d0)
        (:x 0.0d0 :y 0.0d0 :width 12.0d0 :height 10.0d0))
       (2.0d0 2.0d0))
      (((:width 16.0d0 :height 10.0d0)
        (:x 0.0d0 :y 0.0d0 :width 12.0d0 :height 10.0d0))
       (0.0d0 0.0d0))
      (((:width 2.0d0 :height 2.0d0)
        (:x 0.0d0 :y 0.0d0 :width 4.0d0 :height 4.0d0))
       (1.0d0 1.0d0))))
    ("crc32_step"
     (((4294967295 49) 2082672712)
      ((2082672712 50) 2964110130)
      ((2964110130 51) 2008521773)))
    ("crc32_full"
     (((49 50 51 52 53 54 55 56 57) 3421780262)))))

(defun points-p (x) (and (consp x) (every #'numberp x)))

(defun close-p (got want)
  (cond
    ((consp want)
     (and (consp got)
          (= (length got) (length want))
          (loop for g in got for w in want
                always (<= (abs (- (ffloat g) (ffloat w))) *tolerance*))))
    ((numberp want)
     (<= (abs (- (ffloat got) (ffloat want))) *tolerance*))
    (t (equal got want))))

(defun run-tests ()
  (loop for (name cases) in *tests*
        nconc
        (loop for (argv want) in cases collect
          (let ((want-str (if (points-p want)
                              (format nil "point~A" want)
                              (princ-to-string want))))
            (handler-case
                (let* ((got (call-fn name argv))
                       (got-str (if (points-p got)
                                    (format nil "point~A" got)
                                    (princ-to-string got))))
                  (list name want-str got-str (close-p got want)))
              (error (e)
                (list name want-str (format nil "EXC: ~A" e) nil)))))))

;; C generator

(defparameter *preamble*
  "/* generated from s-expression IR (PoC): parse_IR -> emit_C */
#include <math.h>
#include <stdint.h>
#ifndef MAX
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif
#define MIDX(r) ((r).x + (r).width / 2.)
#define MIDY(r) ((r).y + (r).height / 2.)
typedef double CGFloat;
typedef struct { CGFloat x, y; } NSPoint;
typedef struct { CGFloat width, height; } NSSize;
typedef struct { CGFloat x, y, width, height; } NSRect;
")

(defun c-type (t-sym)
  (let ((u (string-upcase (symbol-name t-sym))))
    (cond ((string= u "CGFLOAT") "double")
          ((string= u "UINT32")  "uint32_t")
          ((string= u "NSSIZE")  "NSSize")
          ((string= u "NSPOINT") "NSPoint")
          ((string= u "NSRECT")  "NSRect")
          (t (error "unknown IR type: ~A" u)))))

(defun fmt-num (n)
  (if (integerp n)
      (format nil "~A" n)
      (format nil "~F" n)))

(defun c-expr (node)
  (typecase node
    (number (fmt-num node))
    (symbol (symbol-name node))
    (cons (c-form node))
    (otherwise (error "bad node in C emission: ~S" node))))

(defun c-form (node)
  (let ((op (car node)))
    (if (keywordp op)
        (cond
          ((string= (string-upcase (symbol-name op)) "IF")
           (format nil "(~A ? ~A : ~A)"
                   (c-expr (second node)) (c-expr (third node))
                   (c-expr (fourth node))))
          ((string= (string-upcase (symbol-name op)) "FIELD")
           (format nil "~A.~A"
                   (c-expr (second node)) (symbol-name (third node))))
          ((string= (string-upcase (symbol-name op)) "LET")
           (let ((b (second node))
                 (body (cddr node))
                 (o (make-string-output-stream)))
             (princ "({ " o)
             (loop for j from 0 below (length b) by 2
                   do (format o "uint32_t ~A = ~A; "
                              (symbol-name (nth j b))
                              (c-expr (nth (1+ j) b))))
             (loop for s in body do (princ (c-expr s) o))
             (when (and body
                        (not (string= (string-upcase (symbol-name (car (car (last body))))) "SET")))
               (princ "; " o))
             (princ "})" o)
             (get-output-stream-string o)))
          ((string= (string-upcase (symbol-name op)) "LOOP")
           (let ((n (second node))
                 (body (cddr node))
                 (name (and (car (last (cddr node)))
                            (consp (car (last (cddr node))))
                            (string= (string-upcase (symbol-name (car (car (last (cddr node)))))) "SET")
                            (symbol-name (second (car (last (cddr node))))))))
             (with-output-to-string (o)
               (princ "({ for (int _i = 0; _i < " o)
               (princ (fmt-num n) o)
               (princ "; ++_i) { " o)
               (loop for s in body do (princ (c-expr s) o))
               (princ " } " o)
               (when name (princ name o))
               (princ "; })" o))))
          ((string= (string-upcase (symbol-name op)) "SET")
           (format nil "~A = ~A; "
                   (symbol-name (second node))
                   (c-expr (third node))))
          (t
            (let* ((callee (symbol-name (second node)))
                  (raw-up (string-upcase callee))
                  (args (mapcar #'c-expr (cddr node))))
             (cond
               ((string= raw-up "POINT")
                (format nil "((NSPoint){ ~A, ~A })" (first args) (second args)))
               ((member raw-up '("MIDX" "MIDY") :test #'string=)
                (format nil "~A(~{~A~^, ~})" raw-up args))
               (t (format nil "~A(~{~A~^, ~})" callee args))))))
        (let* ((args (mapcar #'c-expr (cdr node)))
               (u (string-upcase (symbol-name op))))
          (cond
            ((string= u "+") (format nil "(~{~A~^ + ~})" args))
            ((string= u "*") (format nil "(~{~A~^ * ~})" args))
            ((string= u "-")
             (if (null (rest args))
                 (format nil "(-~A)" (first args))
                 (format nil "(~A~{ - ~A~})" (first args) (rest args))))
            ((string= u "/") (format nil "(~A / ~A)" (first args) (second args)))
            ((member u '("MAX" "MIN") :test #'string=)
             (format nil "~A(~A, ~A)" u (first args) (second args)))
            ((string= u "SQRT") (format nil "sqrt(~A)" (first args)))
            ((member u '("ABS" "FABS") :test #'string=)
             (format nil "fabs(~A)" (first args)))
            ((member u '("<" ">" "==") :test #'string=)
             (format nil "(~A ~A ~A)"
                     (first args) (if (string= u "==") "==" u) (second args)))
            ((string= u "XOR") (format nil "((uint32_t)(~A) ^ (uint32_t)(~A))" (first args) (second args)))
            ((string= u "AND") (format nil "((uint32_t)(~A) & (uint32_t)(~A))" (first args) (second args)))
            ((string= u "SHL") (format nil "((uint32_t)(~A) << (uint32_t)(~A))" (first args) (second args)))
            ((string= u "SHR") (format nil "((uint32_t)(~A) >> (uint32_t)(~A))" (first args) (second args)))
            (t (error "no C emission for op: ~A" (symbol-name op))))))))

(defun param-decls (params)
  (loop for j from 0 below (length params) by 2
        nconc (list (c-type (nth (1+ j) params))
                    (symbol-name (nth j params)))))

(defun gen-c (tree)
  (with-output-to-string (o)
    (princ *preamble* o)
    (dolist (form (remove-if-not #'function-form-p tree))
      (multiple-value-bind (name params ret body) (form-parts form)
        (declare (ignore body))
        (format o "static ~A ~A(~{~A ~A~^, ~});~%"
                (c-type ret) name (param-decls params))))
    (dolist (form (remove-if-not #'function-form-p tree))
      (multiple-value-bind (name params ret body) (form-parts form)
        (format o "~%~%static ~A ~A(~{~A ~A~^, ~}) {~%    return ~A;~%}~%"
                (c-type ret) name (param-decls params) (c-expr body))))))

(defun compile-check (source)
  (let* ((n (random 1000000))
         (cpath (format nil "/tmp/opencode/poc~D.c" n))
         (epath (format nil "/tmp/opencode/poc~D.err" n)))
    (with-open-file (f cpath :direction :output :if-exists :supersede)
      (write-string source f))
    (let* ((proc (sb-ext:run-program
                  "/bin/sh"
                  (list "-c"
                        (format nil "gcc -Wall -Wextra -fsyntax-only '~A' 2> '~A'"
                                cpath epath))
                  :search t :wait t))
           (code (sb-ext:process-exit-code proc))
           (err (with-open-file (e epath :direction :input)
                  (let ((s (make-string (file-length e))))
                    (read-sequence s e)
                    (string-trim '(#\Space #\Tab #\Newline) s)))))
      (delete-file cpath)
      (ignore-errors (delete-file epath))
      (list (= code 0) err))))

;; driver

(defun main ()
  (let* ((tree (parse-ir *ir-source*)))
    (register-fns tree)
    (format t "== interpreter vs mock corpus ==~%")
    (let* ((results (run-tests))
           (total (length results))
           (passed (count-if (lambda (r) (fourth r)) results)))
      (loop for (name want got ok) in results
            do (format t "[~:[FAIL~;PASS~]] ~18A want=~A got=~A~%"
                       ok name want got))
      (format t "interp tests: ~D/~D passed~%" passed total)
      (let ((source (gen-c tree)))
        (format t "== emitted C ==~%~A~%" source)
        (destructuring-bind (ok err) (compile-check source)
          (format t "[C]  gcc -Wall -Wextra -fsyntax-only: ~A~A~%"
                  (if ok "OK" "FAIL")
                  (if (string= err "") "" (format nil "  stderr: ~A" err))))
        ;; timing
        (let ((start (get-internal-run-time)))
          (loop repeat 20 do (parse-ir *ir-source*) (run-tests))
          (let ((total-ms (* 1000.0
                             (/ (float (- (get-internal-run-time) start) 1.0d0)
                                (float internal-time-units-per-second 1.0d0)))))
            (format t "[TIMING] avg ~,3F ms/cycle over 20 runs (parse + ~D tests)~%"
                    (/ total-ms 20.0) total)))))))

(defun repl ()
  "Tiny IR REPL: read a form; a :function form registers itself,
anything else evaluates in a fresh env against registered functions."
  (loop
    (format t "IR> ")
    (finish-output)
    (let ((*readtable* (copy-readtable *readtable*)))
      (setf (readtable-case *readtable*) :preserve)
      (let ((form (read)))
        (if (function-form-p form)
            (progn (register-fns (list form)) (princ "registered"))
            (princ (eval-node form (make-hash-table :test 'equal))))
        (terpri)))))
