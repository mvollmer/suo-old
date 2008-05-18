(use-modules (oop goops)
	     (srfi srfi-39)
	     (ice-9 pretty-print)
	     (oop goops)
	     (ice-9 common-list)
	     (ice-9 rdelim))

(debug-enable 'debug)
(debug-enable 'backtrace)
(debug-set! stack 2000000)
(read-enable 'positions)
(read-set! keywords 'prefix)

(set! pk (lambda args
	   (display ";;;")
	   (for-each (lambda (elt)
		       (display " ")
		       (write elt))
		     args)
	   (newline)
	   (car (last-pair args))))

(load "suo-cross.scm")

(boot-load-arch "base")
(boot-load-arch "utilities")
(boot-load-arch "assembler")
(boot-load-arch "compiler")
(boot-load-arch "books")

(define (write-image mem file)
  (let* ((port (open-output-file file)))
    (uniform-vector-write #u32(#xABCD0002 0 0) port)
    (uniform-vector-write mem port)))

(define (make-bootstrap-image exp file)
  (let ((comp-exp (boot-eval
		   `(/base/compile '(:lambda ()
					     ,exp
					     (:primitive syscall (result) ()
							 ((:begin))))))))
    (or (constant? comp-exp)
	(error "expected constant"))
    (write-image (dump-object (constant-value comp-exp))
		 file)))

(define (compile-base)
  (image-compile-arch "base")
  (image-compile-arch "null-compiler")
  (image-compile-arch "books")
  (image-compile-arch "boot")
  (image-import-boot-record-types)
  (image-import-books)
  (make-bootstrap-image (image-expression) "base"))

(define (compile-compiler)
  (image-compile-arch "base")
  (image-compile-arch "utilities")
  ;; (boot-eval '(set! /compiler/cps-verbose #t))
  (image-compile-arch "assembler")
  (image-compile-arch "compiler")
  (image-compile-arch "books")
  (image-compile-arch "boot")
  (image-load-arch "emacs")
  (image-import-boot-record-types)
  (image-import-books)
  (make-bootstrap-image (image-expression) "compiler"))

(define (compile-minimal)
  (boot-eval '(set! /compiler/cps-verbose #t))
  (image-compile-arch "minimal")
  (make-bootstrap-image (image-expression) "minimal"))

(define (compile-test)
  ;;(boot-eval '(set! /compiler/cps-verbose #t))
  (image-eval '(define (foo x) (+ x) (+ x (+ x)))))

;;(boot-eval '(set! /compiler/cps-verbose #t))

;;(compile-base)
;;(compile-compiler)
;;(compile-minimal)
(compile-test)

(check-undefined-variables)
