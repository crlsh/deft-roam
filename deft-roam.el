;;; deft-roam.el --- Deft interface for org-roam -*- lexical-binding: t; -*-

;;; Commentary:
;; Deft interface using org-roam database.
;; Model: load all nodes once, filter in memory (like org-roam-ui).

;;; Code:

(require 'org-roam)

(defgroup deft-roam nil
  "Deft interface for org-roam."
  :group 'org-roam)

(defcustom deft-roam-time-format " %Y-%m-%d %H:%M"
  "Format string for modification times."
  :type 'string
  :group 'deft-roam)

(defcustom deft-roam-incremental-search t
  "Use incremental string search."
  :type 'boolean
  :group 'deft-roam)

(defcustom deft-roam-case-fold-search t
  "If non-nil, searching is case-insensitive."
  :type 'boolean
  :group 'deft-roam)

(defcustom deft-roam-current-sort-method 'mtime
  "Sort method: mtime or title."
  :type 'symbol
  :group 'deft-roam)

(defface deft-roam-header-face
  '((t :inherit font-lock-keyword-face :bold t))
  "Face for header."
  :group 'deft-roam)

(defface deft-roam-filter-string-face
  '((t :inherit font-lock-string-face))
  "Face for filter."
  :group 'deft-roam)

(defface deft-roam-title-face
  '((t :inherit font-lock-function-name-face :bold t))
  "Face for titles."
  :group 'deft-roam)

(defface deft-roam-time-face
  '((t :inherit font-lock-variable-name-face))
  "Face for times."
  :group 'deft-roam)

(defconst deft-roam-buffer "*Deft-Roam*")
(defvar deft-roam-filter-regexp nil)
(defvar deft-roam-all-nodes nil)
(defvar deft-roam-current-nodes nil)
(defvar deft-roam-window-width nil)

(defun deft-roam--get-all-nodes ()
  "Get all nodes from database (org-roam-ui style)."
  (org-roam-db-query
   [:select [id file title (funcall group-concat tag (emacsql-escape-raw \,))]
    :from nodes
    :left-join tags :on (= id node_id)
    :group :by id]))

;; Cache para evitar llamadas repetidas a file-attributes
(defvar deft-roam--mtime-cache (make-hash-table :test 'equal))

(defun deft-roam--node-mtime (node)
  (let* ((file (nth 1 node))
         (cached (gethash file deft-roam--mtime-cache)))
    (or cached
        (when (file-exists-p file)
          (let ((mtime (nth 5 (file-attributes file))))
            (puthash file mtime deft-roam--mtime-cache)
            mtime)))))

(defun deft-roam--sort-nodes (nodes)
  (sort nodes
        (if (eq deft-roam-current-sort-method 'title)
            (lambda (n1 n2)
              (let ((case-fold-search t))
                (string-lessp (or (nth 2 n1) "")
                            (or (nth 2 n2) ""))))
          (lambda (n1 n2)
            (let ((t1 (deft-roam--node-mtime n1))
                  (t2 (deft-roam--node-mtime n2)))
              (and t1 t2 (time-less-p t2 t1)))))))

(defun deft-roam--search-forward (str content)
  "Search for STR in CONTENT using case-fold-search like Deft."
  (let ((case-fold-search deft-roam-case-fold-search))
    (if deft-roam-incremental-search
        (string-match-p (regexp-quote str) content)
      (string-match-p str content))))

(defun deft-roam--match-node (node)
  "Check if NODE matches all filters."
  (if (not deft-roam-filter-regexp)
      node
    (let* ((title (or (nth 2 node) ""))
           (tags (or (nth 3 node) ""))
           (searchable (concat title " " tags)))
      (when (cl-every (lambda (filter)
                       (deft-roam--search-forward filter searchable))
                     deft-roam-filter-regexp)
        node))))

(defun deft-roam--filter-nodes ()
  (setq deft-roam-current-nodes
        (if deft-roam-filter-regexp
            (delq nil (mapcar #'deft-roam--match-node deft-roam-all-nodes))
          deft-roam-all-nodes)))

(defun deft-roam--print-header ()
  (insert (propertize "Deft-Roam" 'face 'deft-roam-header-face))
  (when deft-roam-filter-regexp
    (insert ": ")
    (insert (propertize (mapconcat 'identity
                                  (reverse deft-roam-filter-regexp)
                                  " ")
                       'face 'deft-roam-filter-string-face)))
  (insert "\n\n"))

(defun deft-roam--current-window-width ()
  (if-let ((window (get-buffer-window deft-roam-buffer)))
      (- (window-text-width window) 1)
    80))

(define-button-type 'deft-roam-button
  'action (lambda (btn)
            (org-roam-node-visit
             (org-roam-node-from-id (button-get btn 'node-id))))
  'face 'deft-roam-title-face
  'follow-link t)

(defface deft-roam-tag-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for tags in Deft-Roam.")

(defun deft-roam--node-button (node)
  "Insertar una línea por nodo mostrando título y tags en estilo hashtag."
  (let* ((id (nth 0 node))
         (title (or (nth 2 node) "[No title]"))
         (raw-tags (or (nth 3 node) ""))
         ;; convertir "music-book,idea" → "#music-book #idea" con estilo visual
         (tags (when (not (string-empty-p raw-tags))
                 (mapconcat (lambda (t)
                              (concat "#"
                                      (propertize (string-trim t)
                                                  'face 'deft-roam-tag-face)))
                            (split-string raw-tags ",")
                            " ")))
         (mtime (deft-roam--node-mtime node))
         (mtime-str (when mtime
                      (format-time-string deft-roam-time-format mtime)))
         (mtime-width (if mtime-str (string-width mtime-str) 0))
         (line-width (- deft-roam-window-width mtime-width))
         ;; mostrar título y tags juntos, truncando si es necesario
         (display-line (truncate-string-to-width
                        (string-trim (format "%s   %s" title (or tags "")))
                        (min line-width
                             (string-width (format "%s   %s" title (or tags "")))))))
    (insert-text-button display-line
                        'type 'deft-roam-button
                        'node-id id)
    (when mtime-str
      (while (< (current-column) line-width)
        (insert " "))
      (insert (propertize mtime-str 'face 'deft-roam-time-face)))
    (insert "\n")))


(defun deft-roam--buffer-setup ()
  (let ((inhibit-read-only t))
    (erase-buffer)
    (deft-roam--print-header)
    (if deft-roam-current-nodes
        (mapc #'deft-roam--node-button deft-roam-current-nodes)
      (insert "No nodes.\n")))
  (goto-char (point-min))
  (forward-line 2))

(defun deft-roam-refresh ()
  "Actualizar solo los nodos nuevos o modificados, sin recargar todo."
  (interactive)
  (message "Refreshing changed nodes only...")
  (let ((old-nodes deft-roam-all-nodes)
        (new-nodes (deft-roam--get-all-nodes))
        changed updated)
    ;; comparar cada nodo nuevo con los anteriores
    (dolist (n new-nodes)
      (let* ((id (nth 0 n))
             (file (nth 1 n))
             (old (assoc id old-nodes))
             (old-mtime (and old (deft-roam--node-mtime old)))
             (new-mtime (and (file-exists-p file)
                             (nth 5 (file-attributes file)))))
        (cond
         ;; nuevo archivo
         ((not old)
          (push n changed))
         ;; archivo modificado
         ((and old-mtime new-mtime (time-less-p old-mtime new-mtime))
          (push n changed)))))
    ;; fusionar los cambios con los nodos anteriores
    (setq updated
          (cl-remove-duplicates
           (append changed old-nodes)
           :key #'car :test #'equal))
    (setq deft-roam-all-nodes (deft-roam--sort-nodes updated))
    (deft-roam--refresh-filter)
    (message "Incremental refresh done (%d nodes)" (length deft-roam-all-nodes))))


;; --- reemplazar la definición actual ---

(defvar deft-roam--filter-thread nil)

(defvar deft-roam--filter-timer nil)

(defun deft-roam--update-header-only ()
  "Actualizar solo el encabezado y la línea vacía debajo, sin duplicar nada."
  (when (get-buffer deft-roam-buffer)
    (with-current-buffer deft-roam-buffer
      (let ((inhibit-read-only t)
            (pos (point)))
        (save-excursion
          (goto-char (point-min))
          ;; borrar las tres primeras líneas: título, filtro, línea vacía
          (delete-region (point-min)
                         (progn (forward-line 3) (point)))
          ;; volver a dibujar encabezado completo con su línea vacía
          (deft-roam--print-header))
        (goto-char pos))))

  )


(defun deft-roam--refresh-filter ()
  "Actualizar los resultados de búsqueda en segundo plano con debounce y threads."
  (when deft-roam--filter-timer
    (cancel-timer deft-roam--filter-timer))
  (setq deft-roam--filter-timer
        (run-with-idle-timer
         0.25 nil  ;; espera 250 ms de inactividad antes de filtrar
         (lambda ()
           (when deft-roam--filter-thread
             (thread-signal deft-roam--filter-thread 'quit nil))
           (setq deft-roam--filter-thread
                 (make-thread
                  (lambda ()
                    (let ((result (if deft-roam-filter-regexp
                                      (delq nil (mapcar #'deft-roam--match-node deft-roam-all-nodes))
                                    deft-roam-all-nodes)))
                      (with-current-buffer deft-roam-buffer
                        (setq deft-roam-current-nodes result)
                        (deft-roam--buffer-setup))))))))))

(defun deft-roam-filter-increment ()
  "Agregar carácter al filtro de búsqueda, activando debounce asíncrono."
  (interactive)
  (let ((char (char-to-string last-command-event)))
    (if (and deft-roam-incremental-search (string= char " "))
        (push "" deft-roam-filter-regexp)
      (if (car deft-roam-filter-regexp)
          (setcar deft-roam-filter-regexp
                  (concat (car deft-roam-filter-regexp) char))
        (setq deft-roam-filter-regexp (list char))))
        (deft-roam--update-header-only)

    (deft-roam--refresh-filter)))


(defun deft-roam-filter-clear ()
  (interactive)
  (when deft-roam-filter-regexp
    (setq deft-roam-filter-regexp nil)
    (deft-roam--refresh-filter)))

(defun deft-roam-filter (str)
  (interactive
   (list (read-string "Filter: "
                     (mapconcat 'identity
                               (reverse deft-roam-filter-regexp)
                               " "))))
  (setq deft-roam-filter-regexp
        (if (string-empty-p str)
            nil
          (reverse (split-string str " " t))))
  (deft-roam--refresh-filter))

(defvar deft-roam--last-del-time 0)


(defun deft-roam-filter-decrement ()
  "Borrar carácter del filtro con debounce y actualización inmediata."
  (interactive)
  (let ((str (car deft-roam-filter-regexp)))
    (when str
      (if (> (length str) 0)
          (setcar deft-roam-filter-regexp (substring str 0 -1))
        (pop deft-roam-filter-regexp))))
  (deft-roam--update-header-only)
  (let ((now (float-time)))
    (when (< (- now deft-roam--last-del-time) 0.15)
      (cancel-timer deft-roam--filter-timer))
    (setq deft-roam--last-del-time now)
    (deft-roam--refresh-filter)))



(defun deft-roam-complete ()
  (interactive)
  (cond
   ((button-at (point))
    (push-button))
   ((and deft-roam-current-nodes)
    (org-roam-node-visit
     (org-roam-node-from-id (nth 0 (car deft-roam-current-nodes)))))))

(defun deft-roam-toggle-sort-method ()
  (interactive)
  (setq deft-roam-current-sort-method
        (if (eq deft-roam-current-sort-method 'mtime)
            'title
          'mtime))
  (message "Sort by: %s" deft-roam-current-sort-method)
  (setq deft-roam-all-nodes (deft-roam--sort-nodes deft-roam-all-nodes))
  (deft-roam--refresh-filter))

(defvar deft-roam-mode-map
  (let ((map (make-keymap)))
    (set-char-table-range (nth 1 map) (cons #x100 (max-char))
                         'deft-roam-filter-increment)
    (dotimes (i (- 256 32))
      (define-key map (vector (+ i 32)) 'deft-roam-filter-increment))
    (define-key map (kbd "DEL") 'deft-roam-filter-decrement)
    (define-key map (kbd "RET") 'deft-roam-complete)
    (define-key map (kbd "C-c C-l") 'deft-roam-filter)
    (define-key map (kbd "C-c C-c") 'deft-roam-filter-clear)
    (define-key map (kbd "C-c C-s") 'deft-roam-toggle-sort-method)
    (define-key map (kbd "C-c C-g") 'deft-roam-refresh)
    (define-key map (kbd "C-c C-q") 'quit-window)
    (define-key map (kbd "<tab>") 'forward-button)
    (define-key map (kbd "<backtab>") 'backward-button)
    map))

(define-derived-mode deft-roam-mode special-mode "Deft-Roam"
  "Deft interface for org-roam database."
  (setq truncate-lines t)
  (setq buffer-read-only t)
  (setq deft-roam-window-width (deft-roam--current-window-width))
  (setq deft-roam-filter-regexp nil)
  (message "Loading nodes...")
  (setq deft-roam-all-nodes (deft-roam--get-all-nodes))
  (setq deft-roam-all-nodes (deft-roam--sort-nodes deft-roam-all-nodes))
  (setq deft-roam-current-nodes deft-roam-all-nodes)
  (deft-roam--buffer-setup)
  (message "Loaded %d nodes" (length deft-roam-all-nodes)))

;;;###autoload
(defun deft-roam ()
  "Start Deft-Roam."
  (interactive)
  (switch-to-buffer deft-roam-buffer)
  (unless (eq major-mode 'deft-roam-mode)
    (deft-roam-mode)))

(provide 'deft-roam)
;;; deft-roam.el ends here
