# curl-multi - Ruby bindings for the libcurl multi interface
# Copyright (C) 2007 Philotic, Inc.

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require File.dirname(__FILE__) + '/test_helper.rb'

class TestCurlMulti < Test::Unit::TestCase
  def setup
  end

  def test_get
    c = Curl::Multi.new()
    success = lambda do |body|
      assert body.include? 'html'
    end
    failure = lambda do |ex|
      fail ex
    end
    c.get('http://www.google.com/', success, failure)
    c.select([], []) while c.size > 0
  end
end
