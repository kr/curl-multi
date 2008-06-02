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

$:.unshift File.dirname(__FILE__)

require 'rubygems'
require 'inline'
require 'uri-extensions'
require 'curb'

module Curl
  class Error < RuntimeError
    def initialize(code)
      super("Curl error #{code}")
    end
  end

  class HTTPError < RuntimeError
    def initialize(status)
      super("Curl HTTP error #{status}")
    end
  end

  class MultiError < RuntimeError
    attr_reader :errors
    def initialize(errors)
      @errors = errors
      super("Multiple errors: #{errors}")
    end
  end

  # An instance of this class collects the response for each curl easy handle.
  class Req
    CURLE_OK = 0

    attr_reader :url, :body

    def done(code, status)
      @done = true
      if code != CURLE_OK
        @error = Error.new(code)
      elsif status != 200
        @error = HTTPError.new(status)
      end
    end

    def done?() @done end

    def failed?() !!@error end

    def do_success() @success.call(body) end

    def do_failure() @failure.call(@error) end

    def inspect() "{Curl::Req #{url}}" end
    alias_method :to_s, :inspect

    def initialize(url, success, failure)
      @url = url
      @success = success
      @failure = failure
      @body = ''
      @done = false
      @error = nil
    end

    def add_chunk(chunk)
      @body = body + chunk
    end
  end

  class Multi
    def size() @handles.size end

    def inspect() '{Curl::Multi' + @handles.map{|h| ' '+h.url}.join + '}' end
    alias_method :to_s, :inspect

    def get(url, success, failure=lambda{})
      add(url, nil, success, failure)
    end

    def post(url, params, success, failure=lambda{})
      add(url, URI.escape_params(params), success, failure)
    end

    def select(rfds, wfds)
      loop do
        ready_rfds, ready_wfds = c_select(rfds.map{|s|s.fileno},
                                          wfds.map{|s|s.fileno})
        work() # Curl may or may not have work to do, but we can't tell.
        return ready_rfds, ready_wfds if ready_rfds.any? or ready_wfds.any?
        return [], [] if rfds == [] and wfds == []
      end
    end

    # Do as much work as possible without blocking on the network. That is,
    # read as much data as is ready and write as much data as we have buffer
    # space for. If any complete responses arrive, call their handlers.
    def work
      perform()

      done, @handles = @handles.partition{|h| h.done?}
      failed, done = done.partition{|h| h.failed?}

      errors = []
      errors += post_process(done) {|x| x.do_success}
      errors += post_process(failed) {|x| x.do_failure}
      raise errors[0] if errors.size == 1
      raise MultiError.new(errors) if errors.size > 1

      :ok
    end

    def cleanup
      @handles = []
      :ok
    end

    def initialize
      @handles = []
    end

    # Add a URL to the queue of items to fetch
    def add(url, body, success, failure=lambda{})
      while (h = add_to_curl(Req.new(url, success, failure), url, body)) == nil
        select([], [])
      end
      @handles << h
      work()
      :ok
    end

    def post_process(handles)
      errors = []
      handles.each do |h|
        begin
          yield(h) # This ought not to raise anything.
        rescue => ex
          errors << ex
        end
      end
      return errors
    end

    inline do |builder|
      builder.include('<errno.h>')
      if File.exists?('/usr/include/curl/curl.h')
        builder.include('"/usr/include/curl/curl.h"')
      elsif File.exists?('/opt/csw/include/curl/curl.h')
        builder.include('"/opt/csw/include/curl/curl.h"')
      else
        builder.include('"/usr/local/include/curl/curl.h"')
      end

      builder.prefix <<-end
        #define GET_MULTI_HANDLE(name) \
          CURLM *(name);\
          Data_Get_Struct(self, CURLM, (name));\
          if (!(name)) rb_raise(rb_eTypeError,\
                                "Expected initialized curl multi handle")

        #define CHECK(e) do {\
            if (!(e)) rb_raise(rb_eTypeError, "curl error");\
          } while (0)

        #define CHECKN(e) CHECK(!(e))

        ID id_initialize, id_done, id_add_chunk, id_size;
      end

      builder.c_raw_singleton <<-end
        void c_curl_multi_cleanup(void *x)
        {
          curl_multi_cleanup(x);
        }
      end

      # Creates a new CurlMulti handle
      builder.c_singleton <<-end
        VALUE new() {
          CURLcode r;
          VALUE inst;

          /* can't think of a better place to put this */
          id_initialize = rb_intern("initialize");
          id_done = rb_intern("done");
          id_add_chunk = rb_intern("add_chunk");
          id_size = rb_intern("size");

          /* must be called at least once before any other curl functions */
          r = curl_global_init(CURL_GLOBAL_ALL);
          CHECKN(r);

          inst = Data_Wrap_Struct(self, 0, c_curl_multi_cleanup, curl_multi_init());
          rb_funcall(inst, id_initialize, 0);
          return inst;
        }
      end

      # We tell CurlEasy handles to write to this function in the constructor.
      # The self argument is a parameter we set up with CURLOPT_WRITEDATA that
      # lets us pass whatever data we'd like into the write fn.
      builder.c_raw_singleton <<-end
        uint c_add_chunk(char *chunk, uint size, uint nmemb, VALUE rb_req) {
          uint bytes = size * nmemb; /* Number of bytes of data */
          if (bytes == 0) return 0;

          /* This is (rubyInstance, methodId, numArgs, arg1, arg2...) */
          rb_funcall(rb_req, id_add_chunk, 1, rb_str_new(chunk, bytes));
          return bytes;
        }
      end

      # Adds an easy handle to the multi handle's list
      builder.c <<-end
        VALUE add_to_curl(VALUE rb_req, VALUE url, VALUE body) {
          CURLMcode r;
          GET_MULTI_HANDLE(multi_handle);

          /* We start getting errors if we have too many open connections at
          once, so make a hard limit. */
          if (FIX2INT(rb_funcall(self, id_size, 0)) > 500) return Qnil;

          CURL *easy_handle = curl_easy_init();
          char *c_url = StringValuePtr(url);

          /* Pass it the URL */
          curl_easy_setopt(easy_handle, CURLOPT_URL, c_url);

          /* GET or POST? */
          if (body != Qnil) {
            char *c_body = StringValuePtr(body);
            uint body_sz = RSTRING(body)->len;
            curl_easy_setopt(easy_handle, CURLOPT_POST, 1);
            curl_easy_setopt(easy_handle, CURLOPT_POSTFIELDS, c_body);
            curl_easy_setopt(easy_handle, CURLOPT_POSTFIELDSIZE, body_sz);
          }

          /* Tell curl to use our callbacks */
          curl_easy_setopt(easy_handle, CURLOPT_WRITEFUNCTION, c_add_chunk);

          /* Make curl give us a ruby pointer in the callbacks */
          curl_easy_setopt(easy_handle, CURLOPT_WRITEDATA, rb_req);
          curl_easy_setopt(easy_handle, CURLOPT_PRIVATE, rb_req);

          /* Add it to the multi handle */
          r = curl_multi_add_handle(multi_handle, easy_handle);
          CHECKN(r);

          return rb_req;
        }
      end

      # Wait until one of the given fds or one of curl's fds is ready.
      # Return two arrays of fds that are ready.
      builder.c <<-end
        void c_select(VALUE rfda, VALUE wfda) {
          int i, r, n = -1;
          long timeout;
          fd_set rfds, wfds, efds;
          CURLMcode cr;
          VALUE ready_rfda, ready_wfda;
          struct timeval tv = {0, 0};
          GET_MULTI_HANDLE(multi_handle);

          FD_ZERO(&rfds);
          FD_ZERO(&wfds);
          FD_ZERO(&efds);

          /* Put curl's fds into the sets. */
          cr = curl_multi_fdset(multi_handle, &rfds, &wfds, &efds, &n);
          CHECKN(cr);

          /* Put the given fds into the sets. */
          for (i = 0; i < RARRAY(rfda)->len; i++) {
            int fd = FIX2INT(RARRAY(rfda)->ptr[i]);
            FD_SET(fd, &rfds);
            n = n > fd ? n : fd;
          }
          for (i = 0; i < RARRAY(wfda)->len; i++) {
            int fd = FIX2INT(RARRAY(wfda)->ptr[i]);
            FD_SET(fd, &wfds);
            n = n > fd ? n : fd;
          }

          cr = curl_multi_timeout(multi_handle, &timeout);
          CHECKN(cr);

          tv.tv_sec = timeout / 1000;
          tv.tv_usec = (timeout * 1000) % 1000000;

          /* Wait */
          r = select(n + 1, &rfds, &wfds, &efds, (timeout < 0) ? NULL : &tv);
          if (r < 0) rb_raise(rb_eRuntimeError, "select(): %s", strerror(errno));

          ready_rfda = rb_ary_new();
          ready_wfda = rb_ary_new();

          /* Collect the fds that are ready */
          for (i = 0; i < RARRAY(rfda)->len; i++) {
            VALUE fd = FIX2INT(RARRAY(rfda)->ptr[i]);
            if (FD_ISSET(fd, &rfds)) rb_ary_push(ready_rfda, INT2FIX(fd));
          }
          for (i = 0; i < RARRAY(wfda)->len; i++) {
            VALUE fd = FIX2INT(RARRAY(wfda)->ptr[i]);
            if (FD_ISSET(fd, &wfds)) rb_ary_push(ready_wfda, INT2FIX(fd));
          }

          return rb_ary_new3(2, ready_rfda, ready_wfda);
        }
      end

      # Basically just a wrapper for curl_multi_perform().
      builder.c <<-end
        void perform() {
          CURLMsg *msg;
          CURLcode er;
          CURLMcode r;
          int status;
          int running;
          GET_MULTI_HANDLE(multi_handle);

          /* do some work */
          do {
            r = curl_multi_perform(multi_handle, &running);
          } while (r == CURLM_CALL_MULTI_PERFORM);
          CHECK(r == CURLM_OK);

          /* check which ones are done and mark them as done */
          while ((msg = curl_multi_info_read(multi_handle, &r))) {
            VALUE rb_req;
            CURL *easy_handle;

            if (msg->msg != CURLMSG_DONE) continue;

            /* Save out the easy handle, because the msg struct becomes invalid
             * whene we call curl_easy_cleanup, curl_multi_remove_handle, or
             * curl_easy_cleanup. */
            easy_handle = msg->easy_handle;

            r = curl_easy_getinfo(easy_handle, CURLINFO_PRIVATE, &rb_req);
            CHECKN(r);

            er = curl_easy_getinfo(easy_handle, CURLINFO_RESPONSE_CODE,
                                   &status);
            CHECKN(er);

            rb_funcall(rb_req, id_done, 2, INT2FIX(msg->data.result),
                                           INT2FIX(status));

            r = curl_multi_remove_handle(DATA_PTR(self), easy_handle);
            CHECKN(r);

            /* Free the handle */
            curl_easy_cleanup(easy_handle);
          }
        }
      end
    end
  end
end
