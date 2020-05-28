/*
 *  pamac-vala
 *
 *  Copyright (C) 2014-2020 Guillaume Benoit <guillaume@manjaro.org>
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

// i18n
const string GETTEXT_PACKAGE = "pamac";

const string update_icon_name = "pamac-tray-update";
const string noupdate_icon_name = "pamac-tray-no-update";
const string noupdate_info = _("Your system is up-to-date");

namespace Pamac {
	[DBus (name = "org.manjaro.pamac.daemon")]
	interface Daemon : Object {
		public abstract void set_environment_variables (HashTable<string,string> variables) throws Error;
		public abstract string get_lockfile () throws Error;
		[DBus (no_reply = true)]
		public abstract void quit () throws Error;
		public signal void write_pamac_config_finished ();
	}

	public abstract class TrayIcon: Gtk.Application {
		Notify.Notification notification;
		Daemon system_daemon;
		Config config;
		bool extern_lock;
		uint refresh_timeout_id;
		uint check_lock_timeout_id;
		GLib.File lockfile;
		FileMonitor monitor;
		uint updates_nb;
		Gtk.IconTheme icon_theme;

		protected TrayIcon () {
			application_id = "org.manjaro.pamac.tray";
			flags = ApplicationFlags.FLAGS_NONE;
		}

		void start_system_daemon (HashTable<string,string> environment_variables) {
			if (system_daemon == null) {
				try {
					system_daemon = Bus.get_proxy_sync (BusType.SYSTEM, "org.manjaro.pamac.daemon", "/org/manjaro/pamac/daemon");
					// Set environment variables
					system_daemon.set_environment_variables (environment_variables);
					system_daemon.write_pamac_config_finished.connect (on_write_pamac_config_finished);
				} catch (Error e) {
					warning (e.message);
				}
			}
		}

		void stop_system_daemon () {
			if (!check_pamac_running ()) {
				try {
					system_daemon.quit ();
				} catch (Error e) {
					warning (e.message);
				}
			}
		}

		public abstract void init_status_icon ();

		// Create menu for right button
		public Gtk.Menu create_menu () {
			var menu = new Gtk.Menu ();
			var item = new Gtk.MenuItem.with_label (_("Package Manager"));
			item.activate.connect (execute_manager);
			menu.append (item);
			item = new Gtk.MenuItem.with_mnemonic (_("_Quit"));
			item.activate.connect (this.release);
			menu.append (item);
			menu.show_all ();
			return menu;
		}

		public void left_clicked () {
			if (updates_nb > 0) {
				execute_updater ();
			} else {
				execute_manager ();
			}
		}

		void execute_updater () {
			try {
				Process.spawn_command_line_async ("pamac-manager --updates");
			} catch (SpawnError e) {
				warning (e.message);
			}
		}

		void execute_manager () {
			try {
				Process.spawn_command_line_async ("pamac-manager");
			} catch (SpawnError e) {
				warning (e.message);
			}
		}

		public abstract void set_tooltip (string info);

		public abstract void set_icon (string icon);

		public abstract void set_icon_visible (bool visible);

		bool check_updates () {
			var config = new Config ("/etc/pamac.conf");
			if (config.refresh_period != 0) {
				// get updates
				string[] cmds = {"pamac", "checkupdates", "-q", "--refresh-tmp-files-dbs", "--use-timestamp"};
				if (config.download_updates) {
					cmds+= "--download-updates";
				}
				updates_nb = 0;
				try {
					var process = new Subprocess.newv (cmds, SubprocessFlags.STDOUT_PIPE);
					process.wait_async.begin (null, () => {
						if (process.get_if_exited ()) {
							int status = process.get_exit_status ();
							// status 100 means updates are available
							if (status == 100) {
								var dis = new DataInputStream (process.get_stdout_pipe ());
								// count lines
								try {
									while (dis.read_line () != null) {
										updates_nb++;
									}
								} catch (Error e) {
									warning (e.message);
								}
								show_or_update_notification ();
							} else {
								set_icon (noupdate_icon_name);
								set_tooltip (noupdate_info);
								set_icon_visible (!config.no_update_hide_icon);
								close_notification ();
							}
						}
					});
				} catch (Error e) {
					warning (e.message);
				}
			}
			return true;
		}

		void on_write_pamac_config_finished () {
			config.reload ();
			launch_refresh_timeout (config.refresh_period);
			check_updates ();
		}

		void show_or_update_notification () {
			string info = ngettext ("%u available update", "%u available updates", updates_nb).printf (updates_nb);
			set_icon (update_icon_name);
			set_tooltip (info);
			set_icon_visible (true);
			if (check_pamac_running ()) {
				update_notification (info);
			} else {
				show_notification (info);
			}
		}

		void show_notification (string info) {
			try {
				close_notification ();
				notification = new Notify.Notification (_("Package Manager"), info, "system-software-install-symbolic");
				notification.set_timeout (Notify.EXPIRES_DEFAULT);
				notification.add_action ("default", _("Details"), execute_updater);
				notification.show ();
			} catch (Error e) {
				warning (e.message);
			}
		}

		void update_notification (string info) {
			try {
				if (notification != null) {
					if (notification.get_closed_reason () == -1 && notification.body != info) {
						notification.update (_("Package Manager"), info, "system-software-install-symbolic");
						notification.show ();
					}
				} else {
					show_notification (info);
				}
			} catch (Error e) {
				warning (e.message);
			}
		}

		void close_notification () {
			try {
				if (notification != null && notification.get_closed_reason () == -1) {
					notification.close ();
					notification = null;
				}
			} catch (Error e) {
				warning (e.message);
			}
		}

		bool check_pamac_running () {
			Application app;
			bool run = false;
			app = new Application ("org.manjaro.pamac.manager", 0);
			try {
				app.register ();
			} catch (GLib.Error e) {
				warning (e.message);
			}
			run = app.get_is_remote ();
			if (run) {
				return run;
			}
			app = new Application ("org.manjaro.pamac.installer", 0);
			try {
				app.register ();
			} catch (GLib.Error e) {
				warning (e.message);
			}
			run = app.get_is_remote ();
			return run;
		}

		bool check_lock_and_updates () {
			if (!lockfile.query_exists ()) {
				check_updates ();
			}
			check_lock_timeout_id = 0;
			return false;
		}

		void check_extern_lock (File src, File? dest, FileMonitorEvent event_type) {
			if (event_type == FileMonitorEvent.DELETED) {
				if (check_lock_timeout_id != 0) {
					Source.remove (check_lock_timeout_id);
				}
				check_lock_timeout_id = Timeout.add (500, check_lock_and_updates);
			}
		}

		void launch_refresh_timeout (uint64 refresh_period_in_hours) {
			if (refresh_timeout_id != 0) {
				Source.remove (refresh_timeout_id);
				refresh_timeout_id = 0;
			}
			if (refresh_period_in_hours != 0) {
				refresh_timeout_id = Timeout.add_seconds ((uint) refresh_period_in_hours*3600, check_updates);
			}
		}

		void on_icon_theme_changed () {
			icon_theme = Gtk.IconTheme.get_default ();
			if (updates_nb > 0) {
				set_icon (update_icon_name);
			} else {
				set_icon (noupdate_icon_name);
			}
		}

		public override void startup () {
			// i18n
			Intl.textdomain ("pamac");
			Intl.setlocale (LocaleCategory.ALL, "");

			config = new Config ("/etc/pamac.conf");
			// if refresh period is 0, just return so tray will exit
			if (config.refresh_period == 0) {
				return;
			}

			base.startup ();

			extern_lock = false;
			refresh_timeout_id = 0;

			icon_theme = Gtk.IconTheme.get_default ();
			icon_theme.changed.connect (on_icon_theme_changed);
			init_status_icon ();
			set_icon (noupdate_icon_name);
			set_tooltip (noupdate_info);
			set_icon_visible (!config.no_update_hide_icon);

			Notify.init (_("Package Manager"));

			start_system_daemon (config.environment_variables);
			string lockfile_str = "/var/lib/pacman/db.lck";
			try {
				lockfile_str = system_daemon.get_lockfile ();
			} catch (Error e) {
				warning (e.message);
			}
			stop_system_daemon ();

			lockfile = GLib.File.new_for_path (lockfile_str);
			try {
				monitor = lockfile.monitor (FileMonitorFlags.NONE, null);
				monitor.changed.connect (check_extern_lock);
			} catch (Error e) {
				warning (e.message);
			}
			// wait 30 seconds before check updates
			Timeout.add_seconds (30, () => {
				check_updates ();
				return false;
			});
			launch_refresh_timeout (config.refresh_period);

			this.hold ();
		}

		public override void activate () {
			// nothing to do
		}

	}
}
