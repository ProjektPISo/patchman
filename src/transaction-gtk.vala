/*
 *  pamac-vala
 *
 *  Copyright (C) 2018 Guillaume Benoit <guillaume@manjaro.org>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a get of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

namespace Pamac {
	public class TransactionGtk: Transaction {
		//dialogs
		TransactionSumDialog transaction_sum_dialog;
		public GenericSet<string?> transaction_summary;
		StringBuilder warning_textbuffer;
		string current_action;
		public ProgressBox progress_box;
		uint pulse_timeout_id;
		Vte.Terminal term;
		Vte.Pty pty;
		public Gtk.ScrolledWindow term_window;
		public Gtk.Notebook build_files_notebook;
		//parent window
		public Gtk.ApplicationWindow? application_window { get; construct; }
		// ask_confirmation option
		public bool no_confirm_upgrade { get; set; }
		bool summary_shown;
		bool commit_transaction_answer;

		public TransactionGtk (Database database, Gtk.ApplicationWindow? application_window) {
			Object (database: database, application_window: application_window);
		}

		construct {
			//creating dialogs
			this.application_window = application_window;
			transaction_sum_dialog = new TransactionSumDialog (application_window);
			transaction_summary = new GenericSet<string?> (str_hash, str_equal);
			warning_textbuffer = new StringBuilder ();
			current_action = "";
			progress_box = new ProgressBox ();
			progress_box.progressbar.text = "";
			//creating terminal
			term = new Vte.Terminal ();
			term.set_scrollback_lines (-1);
			term.expand = true;
			term.visible = true;
			var black = Gdk.RGBA ();
			black.parse ("black");
			term.set_color_cursor (black);
			term.button_press_event.connect (on_term_button_press_event);
			term.key_press_event.connect (on_term_key_press_event);
			// creating pty for term
			try {
				pty = term.pty_new_sync (Vte.PtyFlags.NO_HELPER);
			} catch (Error e) {
				stderr.printf ("Error: %s\n", e.message);
			}
			// add term in a grid with a scrollbar
			term_window = new Gtk.ScrolledWindow (null, term.vadjustment);
			term_window.expand = true;
			term_window.visible = true;
			term_window.propagate_natural_height = true;
			term_window.add (term);
			// create build files notebook
			build_files_notebook = new Gtk.Notebook ();
			build_files_notebook.visible = true;
			build_files_notebook.expand = true;
			build_files_notebook.scrollable = true;
			build_files_notebook.enable_popup = true;
			// connect to signal
			emit_action.connect (display_action);
			emit_action_progress.connect (display_action_progress);
			emit_hook_progress.connect (display_hook_progress);
			emit_script_output.connect (show_in_term);
			emit_warning.connect ((msg) => {
				show_in_term (msg);
				warning_textbuffer.append (msg + "\n");
			});
			emit_error.connect (display_error);
			finished.connect (on_finished);
			sysupgrade_finished.connect (on_finished);
			start_generating_mirrors_list.connect (start_progressbar_pulse);
			generate_mirrors_list_finished.connect (reset_progress_box);
			start_preparing.connect (start_progressbar_pulse);
			stop_preparing.connect (stop_progressbar_pulse);
			start_building.connect (start_progressbar_pulse);
			stop_building.connect (stop_progressbar_pulse);
			write_pamac_config_finished.connect (set_trans_flags);
			// notify
			Notify.init (dgettext (null, "Package Manager"));
			// flags
			set_trans_flags ();
			// ask_confirmation option
			no_confirm_upgrade = false;
			summary_shown = false;
			commit_transaction_answer = false;
		}

		void set_trans_flags () {
			flags = (1 << 4); //Alpm.TransFlag.CASCADE
			if (database.config.recurse) {
				flags |= (1 << 5); //Alpm.TransFlag.RECURSE
			}
		}

		bool on_term_button_press_event (Gdk.EventButton event) {
			// Check if right mouse button was clicked
			if (event.type == Gdk.EventType.BUTTON_PRESS && event.button == 3) {
				if (term.get_has_selection ()) {
					var right_click_menu = new Gtk.Menu ();
					var copy_item = new Gtk.MenuItem.with_label (dgettext (null, "Copy"));
					copy_item.activate.connect (() => {term.copy_clipboard ();});
					right_click_menu.append (copy_item);
					right_click_menu.show_all ();
					right_click_menu.popup_at_pointer (event);
					return true;
				}
			}
			return false;
		}

		bool on_term_key_press_event (Gdk.EventKey event) {
			// Check if Ctrl + c keys were pressed
			if (((event.state & Gdk.ModifierType.CONTROL_MASK) != 0) && (Gdk.keyval_name (event.keyval) == "c")) {
				term.copy_clipboard ();
				return true;
			}
			return false;
		}

		void show_in_term (string message) {
			term.set_pty (pty);
			try {
				Process.spawn_async (null, {"echo", message}, null, SpawnFlags.SEARCH_PATH, pty.child_setup, null);
			} catch (SpawnError e) {
				stderr.printf ("SpawnError: %s\n", e.message);
			}
		}

		void display_action (string action) {
			if (action != current_action) {
				current_action = action;
				show_in_term (action);
				progress_box.action_label.label = action;
				if (pulse_timeout_id == 0) {
					progress_box.progressbar.fraction = 0;
				}
				progress_box.progressbar.text = "";
			}
		}

		void display_action_progress (string action, string status, double progress) {
			if (action != current_action) {
				current_action = action;
				show_in_term (action);
				progress_box.action_label.label = action;
			}
			progress_box.progressbar.fraction = progress;
			progress_box.progressbar.text = status;
		}

		void display_hook_progress (string action, string details, string status, double progress) {
			if (action != current_action) {
				current_action = action;
				show_in_term (action);
				progress_box.action_label.label = action;
			}
			show_in_term (details);
			progress_box.progressbar.fraction = progress;
			progress_box.progressbar.text = status;
		}

		public void reset_progress_box () {
			current_action = "";
			progress_box.action_label.label = "";
			stop_progressbar_pulse ();
			progress_box.progressbar.fraction = 0;
			progress_box.progressbar.text = "";
		}

		public void start_progressbar_pulse () {
			stop_progressbar_pulse ();
			pulse_timeout_id = Timeout.add (500, (GLib.SourceFunc) progress_box.progressbar.pulse);
		}

		public void stop_progressbar_pulse () {
			if (pulse_timeout_id != 0) {
				Source.remove (pulse_timeout_id);
				pulse_timeout_id = 0;
				progress_box.progressbar.fraction = 0;
			}
		}

		protected override int choose_provider (string depend, string[] providers) {
			var choose_provider_dialog = new ChooseProviderDialog (application_window);
			choose_provider_dialog.title = dgettext (null, "Choose a provider for %s").printf (depend);
			unowned Gtk.Box box = choose_provider_dialog.get_content_area ();
			Gtk.RadioButton? last_radiobutton = null;
			Gtk.RadioButton? first_radiobutton = null;
			foreach (unowned string provider in providers) {
				var radiobutton = new Gtk.RadioButton.with_label_from_widget (last_radiobutton, provider);
				radiobutton.visible = true;
				// active first provider
				if (last_radiobutton == null) {
					radiobutton.active = true;
					first_radiobutton = radiobutton;
				}
				last_radiobutton = radiobutton;
				box.add (radiobutton);
			}
			choose_provider_dialog.run ();
			// get active provider
			int index = 0;
			// list is given in reverse order so reverse it !
			SList<unowned Gtk.RadioButton> list = last_radiobutton.get_group ().copy ();
			list.reverse ();
			foreach (var radiobutton in list) {
				if (radiobutton.active) {
					break;
				}
				index++;
			}
			choose_provider_dialog.destroy ();
			return index;
		}

		protected override bool ask_edit_build_files (TransactionSummary summary) {
			bool answer = false;
			summary_shown = true;
			int response = show_summary (summary);
			if (response == Gtk.ResponseType.OK) {
				// Commit
				commit_transaction_answer = true;
			} else if (response == Gtk.ResponseType.CANCEL) {
				// Cancel transaction
				commit_transaction_answer = false;
			} else if (response == Gtk.ResponseType.REJECT) {
				// Edit build files
				answer = true;
			}
			return answer;
		}

		protected override bool ask_commit (TransactionSummary summary) {
			if (summary_shown) {
				summary_shown = false;
				return commit_transaction_answer;
			} else {
				uint must_confirm_length = summary.to_install.length ()
									+ summary.to_downgrade.length ()
									+ summary.to_reinstall.length ()
									+ summary.to_remove.length ()
									+ summary.to_build.length ();
				if (no_confirm_upgrade
					&& must_confirm_length == 0
					&& summary.to_upgrade.length () > 0) {
					return true;
				}
				summary_shown = true;
				int response = show_summary (summary);
				if (response == Gtk.ResponseType.OK) {
					// Commit
					return true;
				}
			}
			return false;
		}

		int show_summary (TransactionSummary summary) {
			uint64 dsize = 0;
			transaction_summary.remove_all ();
			transaction_sum_dialog.sum_list.clear ();
			transaction_sum_dialog.edit_button.visible = false;
			var iter = Gtk.TreeIter ();
			if (summary.to_remove.length () > 0) {
				foreach (unowned Package infos in summary.to_remove) {
					transaction_summary.add (infos.name);
					transaction_sum_dialog.sum_list.insert_with_values (out iter, -1,
												1, infos.name,
												2, infos.version);
				}
				Gtk.TreePath path = transaction_sum_dialog.sum_list.get_path (iter);
				uint pos = (path.get_indices ()[0]) - (summary.to_remove.length () - 1);
				transaction_sum_dialog.sum_list.get_iter (out iter, new Gtk.TreePath.from_indices (pos));
				transaction_sum_dialog.sum_list.set (iter, 0, "<b>%s</b>".printf (dgettext (null, "To remove") + ":"));
			}
			if (summary.aur_conflicts_to_remove.length () > 0) {
				// do not add type enum because it is just infos
				foreach (unowned Package infos in summary.aur_conflicts_to_remove) {
					transaction_summary.add (infos.name);
					transaction_sum_dialog.sum_list.insert_with_values (out iter, -1,
												1, infos.name,
												2, infos.version);
				}
				Gtk.TreePath path = transaction_sum_dialog.sum_list.get_path (iter);
				uint pos = (path.get_indices ()[0]) - (summary.aur_conflicts_to_remove.length () - 1);
				transaction_sum_dialog.sum_list.get_iter (out iter, new Gtk.TreePath.from_indices (pos));
				transaction_sum_dialog.sum_list.set (iter, 0, "<b>%s</b>".printf (dgettext (null, "To remove") + ":"));
			}
			if (summary.to_downgrade.length () > 0) {
				foreach (unowned Package infos in summary.to_downgrade) {
					dsize += infos.download_size;
					transaction_summary.add (infos.name);
					transaction_sum_dialog.sum_list.insert_with_values (out iter, -1,
												1, infos.name,
												2, infos.version,
												3, "(%s)".printf (infos.installed_version));
				}
				Gtk.TreePath path = transaction_sum_dialog.sum_list.get_path (iter);
				uint pos = (path.get_indices ()[0]) - (summary.to_downgrade.length () - 1);
				transaction_sum_dialog.sum_list.get_iter (out iter, new Gtk.TreePath.from_indices (pos));
				transaction_sum_dialog.sum_list.set (iter, 0, "<b>%s</b>".printf (dgettext (null, "To downgrade") + ":"));
			}
			if (summary.to_build.length () > 0) {
				transaction_sum_dialog.edit_button.visible = true;
				foreach (unowned AURPackage infos in summary.to_build) {
					transaction_summary.add (infos.name);
					transaction_sum_dialog.sum_list.insert_with_values (out iter, -1,
												1, infos.name,
												2, infos.version);
				}
				Gtk.TreePath path = transaction_sum_dialog.sum_list.get_path (iter);
				uint pos = (path.get_indices ()[0]) - (summary.to_build.length () - 1);
				transaction_sum_dialog.sum_list.get_iter (out iter, new Gtk.TreePath.from_indices (pos));
				transaction_sum_dialog.sum_list.set (iter, 0, "<b>%s</b>".printf (dgettext (null, "To build") + ":"));
			}
			if (summary.to_install.length () > 0) {
				foreach (unowned Package infos in summary.to_install) {
					dsize += infos.download_size;
					transaction_summary.add (infos.name);
					transaction_sum_dialog.sum_list.insert_with_values (out iter, -1,
												1, infos.name,
												2, infos.version);
				}
				Gtk.TreePath path = transaction_sum_dialog.sum_list.get_path (iter);
				uint pos = (path.get_indices ()[0]) - (summary.to_install.length () - 1);
				transaction_sum_dialog.sum_list.get_iter (out iter, new Gtk.TreePath.from_indices (pos));
				transaction_sum_dialog.sum_list.set (iter, 0, "<b>%s</b>".printf (dgettext (null, "To install") + ":"));
			}
			if (summary.to_reinstall.length () > 0) {
				foreach (unowned Package infos in summary.to_reinstall) {
					dsize += infos.download_size;
					transaction_summary.add (infos.name);
					transaction_sum_dialog.sum_list.insert_with_values (out iter, -1,
												1, infos.name,
												2, infos.version);
				}
				Gtk.TreePath path = transaction_sum_dialog.sum_list.get_path (iter);
				uint pos = (path.get_indices ()[0]) - (summary.to_reinstall.length () - 1);
				transaction_sum_dialog.sum_list.get_iter (out iter, new Gtk.TreePath.from_indices (pos));
				transaction_sum_dialog.sum_list.set (iter, 0, "<b>%s</b>".printf (dgettext (null, "To reinstall") + ":"));
			}
			if (summary.to_upgrade.length () > 0) {
				if (!no_confirm_upgrade) {
					foreach (unowned Package infos in summary.to_upgrade) {
						dsize += infos.download_size;
						transaction_summary.add (infos.name);
						transaction_sum_dialog.sum_list.insert_with_values (out iter, -1,
													1, infos.name,
													2, infos.version,
													3, "(%s)".printf (infos.installed_version));
					}
					Gtk.TreePath path = transaction_sum_dialog.sum_list.get_path (iter);
					uint pos = (path.get_indices ()[0]) - (summary.to_upgrade.length () - 1);
					transaction_sum_dialog.sum_list.get_iter (out iter, new Gtk.TreePath.from_indices (pos));
					transaction_sum_dialog.sum_list.set (iter, 0, "<b>%s</b>".printf (dgettext (null, "To upgrade") + ":"));
				}
			}
			if (dsize == 0) {
				transaction_sum_dialog.top_label.visible = false;
			} else {
				transaction_sum_dialog.top_label.set_markup ("<b>%s: %s</b>".printf (dgettext (null, "Total download size"), format_size (dsize)));
				transaction_sum_dialog.top_label.visible = true;
			}
			if (transaction_summary.length == 0) {
				// empty summary comes in case of transaction preparation failure
				// with pkgs to build so we show warnings ans ask to edit build files
				transaction_sum_dialog.edit_button.visible = true;
				if (warning_textbuffer.len > 0) {
					transaction_sum_dialog.sum_list.insert_with_values (out iter, -1,
												0, Markup.escape_text (warning_textbuffer.str));
					warning_textbuffer = new StringBuilder ();
				} else {
					transaction_sum_dialog.sum_list.insert_with_values (out iter, -1,
												0, dgettext (null, "Failed to prepare transaction"));
				}
			} else {
				show_warnings (true);
			}
			int response = transaction_sum_dialog.run ();
			transaction_sum_dialog.hide ();
			return response;
		}

		public void destroy_widget (Gtk.Widget widget) {
			widget.destroy ();
		}

		protected override async bool edit_build_files (string[] pkgnames) {
			bool success = true;
			foreach (unowned string pkgname in pkgnames) {
				string action = dgettext (null, "Edit %s build files".printf (pkgname));
				display_action (action);
				// remove noteboook from manager_window properties stack
				unowned Gtk.Stack? stack = build_files_notebook.get_parent () as Gtk.Stack;
				if (stack != null) {
					stack.remove (build_files_notebook);
				}
				// create dialog
				var flags = Gtk.DialogFlags.MODAL;
				int use_header_bar;
				Gtk.Settings.get_default ().get ("gtk-dialogs-use-header", out use_header_bar);
				if (use_header_bar == 1) {
					flags |= Gtk.DialogFlags.USE_HEADER_BAR;
				}
				var dialog = new Gtk.Dialog.with_buttons (action,
														application_window,
														flags);
				dialog.icon_name = "system-software-install";
				dialog.add_button (dgettext (null, "Save"), Gtk.ResponseType.CLOSE);
				unowned Gtk.Widget widget = dialog.add_button (dgettext (null, "_Cancel"), Gtk.ResponseType.CANCEL);
				widget.can_focus = true;
				widget.has_focus = true;
				widget.can_default = true;
				widget.has_default = true;
				unowned Gtk.Box box = dialog.get_content_area ();
				box.margin_bottom = 6;
				build_files_notebook.margin = 6;
				box.add (build_files_notebook);
				dialog.default_width = 700;
				dialog.default_height = 500;
				// populate notebook
				success = yield populate_build_files (pkgname, false, false);
				// run
				int response = dialog.run ();
				// re-add noteboook to manager_window properties stack
				box.remove (build_files_notebook);
				build_files_notebook.margin = 0;
				if (stack != null) {
					stack.add_named (build_files_notebook, "build_files");
				}
				dialog.destroy ();
				if (response == Gtk.ResponseType.CLOSE) {
					// save modifications
					success = yield save_build_files (pkgname);
				}
				if (!success) {
					break;
				}
			}
			return success;
		}

		async bool create_build_files_tab (string filename, bool editable = true) {
			var file = File.new_for_path (filename);
			try {
				StringBuilder text = new StringBuilder ();
				var fis = yield file.read_async ();
				var dis = new DataInputStream (fis);
				string line;
				while ((line = yield dis.read_line_async ()) != null) {
					text.append (line);
					text.append ("\n");
				}
				var scrolled_window = new Gtk.ScrolledWindow (null, null);
				scrolled_window.visible = true;
				var textview = new Gtk.TextView ();
				textview.visible = true;
				textview.editable = editable;
				textview.wrap_mode = Gtk.WrapMode.NONE;
				textview.set_monospace (true);
				textview.input_hints = Gtk.InputHints.NO_EMOJI;
				textview.top_margin = 8;
				textview.bottom_margin = 8;
				textview.left_margin = 8;
				textview.right_margin = 8;
				textview.buffer.set_text (text.str, (int) text.len);
				textview.buffer.set_modified (false);
				if (editable) {
					Gtk.TextIter iter;
					textview.buffer.get_start_iter (out iter);
					textview.buffer.place_cursor (iter);
				} else {
					textview.cursor_visible = false;
				}
				scrolled_window.add (textview);
				var label =  new Gtk.Label (file.get_basename ());
				label.visible = true;
				build_files_notebook.append_page (scrolled_window, label);
			} catch (GLib.Error e) {
				stderr.printf ("%s\n", e.message);
				return false;
			}
			return true;
		}

		public async bool populate_build_files (string pkgname, bool clone, bool overwrite) {
			build_files_notebook.foreach (destroy_widget);
			if (clone) {
				File? clone_dir = yield database.clone_build_files (pkgname, overwrite);
				if (clone_dir == null) {
					// error
					return false;
				}
			}
			bool success = true;
			string[] file_paths = yield get_build_files (pkgname);
			foreach (unowned string path in file_paths) {
				if ("PKGBUILD" in path) {
					success = yield create_build_files_tab (path);
					// add diff after PKGBUILD, do not failed if no diff
					string diff_path = Path.build_path ("/", database.config.aur_build_dir, pkgname, "diff");
					var diff_file = File.new_for_path (diff_path);
					if (diff_file.query_exists ()) {
						success = yield create_build_files_tab (diff_path, false);
					}
				} else {
					// other file
					success = yield create_build_files_tab (path);
				}
				if (!success) {
					break;
				}
			}
			return success;
		}

		public async bool save_build_files (string pkgname) {
			bool success = true;
			int num_pages = build_files_notebook.get_n_pages ();
			int index = 0;
			while (index < num_pages) {
				Gtk.Widget child = build_files_notebook.get_nth_page (index);
				var scrolled_window = child as Gtk.ScrolledWindow;
				var textview = scrolled_window.get_child () as Gtk.TextView;
				if (textview.buffer.get_modified () == true) {
					string pkgdir_name = Path.build_path ("/", database.config.aur_build_dir, pkgname);
					string file_name = Path.build_path ("/", pkgdir_name, build_files_notebook.get_tab_label_text (child));
					var file = File.new_for_path (file_name);
					Gtk.TextIter start_iter;
					Gtk.TextIter end_iter;
					textview.buffer.get_start_iter (out start_iter);
					textview.buffer.get_end_iter (out end_iter);
					try {
						// delete the file before rewrite it
						yield file.delete_async ();
						// creating a DataOutputStream to the file
						var dos = new DataOutputStream (yield file.create_async (FileCreateFlags.REPLACE_DESTINATION));
						// writing a string to the stream
						dos.put_string (textview.buffer.get_text (start_iter, end_iter, false));
						if (build_files_notebook.get_tab_label_text (child) == "PKGBUILD") {
							success = yield regenerate_srcinfo (pkgname);
						}
					} catch (GLib.Error e) {
						stderr.printf("%s\n", e.message);
						success = false;
					}
				}
				if (!success) {
					break;
				}
				index++;
			}
			return success;
		}

		void show_warnings (bool block) {
			if (warning_textbuffer.len > 0) {
				var flags = Gtk.DialogFlags.MODAL;
				int use_header_bar;
				Gtk.Settings.get_default ().get ("gtk-dialogs-use-header", out use_header_bar);
				if (use_header_bar == 1) {
					flags |= Gtk.DialogFlags.USE_HEADER_BAR;
				}
				var dialog = new Gtk.Dialog.with_buttons (dgettext (null, "Warning"),
														application_window,
														flags);
				dialog.border_width = 6;
				dialog.icon_name = "system-software-install";
				dialog.deletable = false;
				unowned Gtk.Widget widget = dialog.add_button (dgettext (null, "_Close"), Gtk.ResponseType.CLOSE);
				widget.can_focus = true;
				widget.has_focus = true;
				widget.can_default = true;
				widget.has_default = true;
				var scrolledwindow = new Gtk.ScrolledWindow (null, null);
				var label = new Gtk.Label (warning_textbuffer.str);
				label.selectable = true;
				label.margin = 12;
				scrolledwindow.visible = true;
				label.visible = true;
				scrolledwindow.add (label);
				scrolledwindow.expand = true;
				unowned Gtk.Box box = dialog.get_content_area ();
				box.add (scrolledwindow);
				dialog.default_width = 600;
				dialog.default_height = 300;
				if (block) {
					dialog.run ();
					dialog.destroy ();
				} else {
					dialog.response.connect (() => {
						dialog.destroy ();
					});
					dialog.show ();
				}
				warning_textbuffer = new StringBuilder ();
			}
		}

		public void display_error (string message, string[] details) {
			reset_progress_box ();
			var flags = Gtk.DialogFlags.MODAL;
			int use_header_bar;
			Gtk.Settings.get_default ().get ("gtk-dialogs-use-header", out use_header_bar);
			if (use_header_bar == 1) {
				flags |= Gtk.DialogFlags.USE_HEADER_BAR;
			}
			var dialog = new Gtk.Dialog.with_buttons (message,
													application_window,
													flags);
			dialog.border_width = 6;
			dialog.icon_name = "system-software-install";
			var textbuffer = new StringBuilder ();
			if (details.length != 0) {
				show_in_term (message + ":");
				foreach (unowned string detail in details) {
					show_in_term (detail);
					textbuffer.append (detail + "\n");
				}
			} else {
				show_in_term (message);
				textbuffer.append (message);
			}
			dialog.deletable = false;
			unowned Gtk.Widget widget = dialog.add_button (dgettext (null, "_Close"), Gtk.ResponseType.CLOSE);
			widget.can_focus = true;
			widget.has_focus = true;
			widget.can_default = true;
			widget.has_default = true;
			var scrolledwindow = new Gtk.ScrolledWindow (null, null);
			var label = new Gtk.Label (textbuffer.str);
			label.selectable = true;
			label.margin = 12;
			scrolledwindow.visible = true;
			label.visible = true;
			scrolledwindow.add (label);
			scrolledwindow.expand = true;
			unowned Gtk.Box box = dialog.get_content_area ();
			box.add (scrolledwindow);
			dialog.default_width = 600;
			dialog.default_height = 300;
			Timeout.add (1000, () => {
				try {
					var notification = new Notify.Notification (dgettext (null, "Package Manager"),
																message,
																"system-software-update");
					notification.show ();
				} catch (Error e) {
					stderr.printf ("Notify Error: %s", e.message);
				}
				return false;
			});
			dialog.run ();
			dialog.destroy ();
		}

		void on_finished (bool success) {
			if (success) {
				try {
					var notification = new Notify.Notification (dgettext (null, "Package Manager"),
																dgettext (null, "Transaction successfully finished"),
																"system-software-update");
					notification.show ();
				} catch (Error e) {
					stderr.printf ("Notify Error: %s", e.message);
				}
				show_warnings (false);
			} else {
				warning_textbuffer = new StringBuilder ();
			}
			summary_shown = false;
			transaction_summary.remove_all ();
			reset_progress_box ();
			show_in_term ("");
		}
	}
}
