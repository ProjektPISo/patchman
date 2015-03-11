/*
 *  pamac-vala
 *
 *  Copyright (C) 2014 Guillaume Benoit <guillaume@manjaro.org>
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
	[DBus (name = "org.manjaro.pamac")]
	public interface Daemon : Object {
		public abstract void start_refresh (int force, bool emit_signal) throws IOError;
	}
}

int main (string[] args) {
	Pamac.Daemon daemon;
	try {
		daemon = Bus.get_proxy_sync (BusType.SYSTEM, "org.manjaro.pamac",
												"/org/manjaro/pamac");
		daemon.start_refresh (0, false);
	} catch (IOError e) {
		stderr.printf ("IOError: %s\n", e.message);
	}
	return 0;
}