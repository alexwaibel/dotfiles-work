;;; capture-idea.el --- deterministic org-roam idea capture -*- lexical-binding: t; -*-
;;
;; Creates a dedicated org-roam node for an idea and links it back to the
;; central "Ideas" hub node, so the hub's backlinks are the living idea backlog.
;;
;; Division of labour:
;;   - Emacs/org-roam own node birth: the :ID:, #+title, slug filename, and
;;     org-roam DB registration (via `org-roam-capture-' + `org-roam-db-update-file').
;;   - The AI writes the idea BODY as org-mode and passes it in a file; we insert
;;     it LITERALLY. Body text is never routed through org-capture templates,
;;     because template %-escapes corrupt ordinary content (e.g. "24%", "%t").
;;
;; Every node is self-identifying as AI-created for later cleanup, via:
;;   - an `#ai' filetag on the node, and
;;   - a `:CAPTURED_BY: copilot-cli' + `:CAPTURED_AT:' file-level property.

(require 'org-roam)

(defconst awb/capture-idea-marker "copilot-cli"
  "Value stored in the :CAPTURED_BY: property of AI-captured idea nodes.")

(defun awb/capture-idea (title body-file ideas-id)
  "Create an org-roam idea node titled TITLE with body read from BODY-FILE.
Link it to the Ideas hub node whose org-id is IDEAS-ID. Returns the new
node's file path. Fully non-interactive.

BODY-FILE must contain valid org-mode; it is inserted verbatim. A
backlink to the hub, an `#ai' filetag, and :CAPTURED_BY:/:CAPTURED_AT:
properties are added automatically."
  (let* ((old org-roam-capture-templates)
         (node (org-roam-node-create :title title))
         path)
    (unwind-protect
        (progn
          ;; Header-only template: no user content passes through %-expansion.
          (setq org-roam-capture-templates
                '(("z" "idea" plain ""
                   :target (file+head "pages/${slug}.org"
                            ":PROPERTIES:\n:ID:       %(org-id-new)\n:END:\n#+title: ${title}\n")
                   :immediate-finish t :unnarrowed t)))
          (org-roam-capture- :node node :keys "z")
          (setq path (org-roam-node-file (org-roam-node-from-title-or-alias title)))
          (with-current-buffer (find-file-noselect path)
            (goto-char (point-min))
            ;; File-level AI markers into the top property drawer.
            (when (re-search-forward "^:END:$" nil t)
              (beginning-of-line)
              (insert (format ":CAPTURED_BY: %s\n:CAPTURED_AT: %s\n"
                              awb/capture-idea-marker
                              (format-time-string "[%Y-%m-%d %a %H:%M]"))))
            ;; #+filetags after #+title so the node carries the :ai: tag.
            (goto-char (point-min))
            (when (re-search-forward "^#\\+title:.*$" nil t)
              (end-of-line)
              (insert "\n#+filetags: :ai:"))
            ;; Backlink to the Ideas hub, then the AI-authored body, verbatim.
            (goto-char (point-max))
            (insert (format "\n- Part of [[id:%s][Ideas]]\n\n" ideas-id))
            (insert-file-contents body-file)
            (save-buffer)
            (org-roam-db-update-file path))
          (message "capture-idea: created node %s" path)
          path)
      (setq org-roam-capture-templates old))))

(provide 'capture-idea)
;;; capture-idea.el ends here
