;;; A do-nothing compiler

;; This is used to quickly test changes to the bootstrapping process
;; when bootstrapping the real compiler would be too slow.

(define (compile exp)
  (macroexpand exp))
