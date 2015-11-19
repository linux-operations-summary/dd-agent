require './ci/common'

def mysql_version
  ENV['FLAVOR_VERSION'] || '5.7.9'
end


def mysql_rootdir
  "#{ENV['INTEGRATIONS_DIR']}/mysql_#{mysql_version}"
end

namespace :ci do
  namespace :mysql_flav do |flavor|
    task before_install: ['ci:common:before_install']

    task install: ['ci:common:install'] do
      # Downloads
      # https://github.com/postgres/postgres/archive/#{pg_version}.tar.gz
      unless Dir.exist? File.expand_path(mysql_rootdir)
        if `uname`.strip == 'Darwin'
          target = 'osx10.10'
        else
          target = 'linux-glibc2.5'
        end
        sh %(curl -s -L\
             -o $VOLATILE_DIR/mysql-#{mysql_version}.tar.gz \
             https://dev.mysql.com/get/Downloads/MySQL-5.7/mysql-#{mysql_version}-#{target}-x86_64.tar.gz)

             #https://s3.amazonaws.com/dd-agent-tarball-mirror/#{pg_version}.tar.gz)
        if `uname`.strip == 'Darwin'
          sh %(tar zxf $VOLATILE_DIR/mysql-#{mysql_version}.tar.gz\
               -C #{mysql_rootdir} --strip-components=1)
        else
          sh %(mkdir -p $VOLATILE_DIR/mysql)
          sh %(tar zxf $VOLATILE_DIR/mysql-#{mysql_version}.tar.gz\
               -C $VOLATILE_DIR/mysql --strip-components=1)
          sh %(cd $VOLATILE_DIR/mysql \
               && cmake . -LH -DCMAKE_INSTALL_PREFIX=#{mysql_rootdir} \
               && ccmake .)
        end
      end
    end

    task before_script: ['ci:common:before_script'] do
      # does travis have any mysql instance already running? :X
      # use another port?
      sh %(mkdir -p #{mysql_rootdir}/data)
      sh %(#{mysql_rootdir}/bin/mysqld --no-defaults --initialize --basedir=#{mysql_rootdir} --datadir=#{mysql_rootdir}/data --plugin-dir=#{mysql_rootdir}/lib/plugin --log-error=#{mysql_rootdir}/data/mysql-init.err --socket=#{mysql_rootdir}/data/mysql.sock --pid-file=#{mysql_rootdir}/data/mysqld_safe.pid --port=3308 --performance-schema)
      sleep_for 5
      `pgrep -f "#{mysql_rootdir}/bin/mysqld" `.split("\n").each do |spid|
          p = spid.to_i
          puts "Stopping #{p}"
          Process.kill "TERM", p
      end
      sleep_for 2
      passwd = ''
      File.open("#{mysql_rootdir}/data/mysql-init.err").each do |line|
          if match = line.match("A temporary password is generated for root@localhost: (.*)$")
              passwd = match.captures.first
              break
          end
      end

      sh %(#{mysql_rootdir}/bin/mysqld --no-defaults --basedir=#{mysql_rootdir} --datadir=#{mysql_rootdir}/data --log-error=#{mysql_rootdir}/data/mysql.err --socket=#{mysql_rootdir}/data/mysql.sock --pid-file=#{mysql_rootdir}/data/mysqld_safe.pid --port=3308 --performance-schema --daemonize >/dev/null 2>&1)
      Wait.for 33_08, 10
      #reset root password
      sh %(#{mysql_rootdir}/bin/mysql --connect-expired-password -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('');" -uroot -p'#{passwd}' --socket=#{mysql_rootdir}/data/mysql.sock)
      sh %(#{mysql_rootdir}/bin/mysql -e "create user 'dog'@'localhost' identified by 'dog'" -uroot --socket=#{mysql_rootdir}/data/mysql.sock)
      sh %(#{mysql_rootdir}/bin/mysql -e "GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'dog'@'localhost' WITH MAX_USER_CONNECTIONS 5;" -uroot --socket=#{mysql_rootdir}/data/mysql.sock)
      sh %(#{mysql_rootdir}/bin/mysql -e "CREATE DATABASE testdb;" -uroot --socket=#{mysql_rootdir}/data/mysql.sock)
      sh %(#{mysql_rootdir}/bin/mysql -e "CREATE TABLE testdb.users (name VARCHAR(20), age INT);" -uroot --socket=#{mysql_rootdir}/data/mysql.sock)
      sh %(#{mysql_rootdir}/bin/mysql -e "GRANT SELECT ON testdb.users TO 'dog'@'localhost';" -uroot --socket=#{mysql_rootdir}/data/mysql.sock)
      sh %(#{mysql_rootdir}/bin/mysql -e "INSERT INTO testdb.users (name,age) VALUES('Alice',25);" -uroot --socket=#{mysql_rootdir}/data/mysql.sock)
      sh %(#{mysql_rootdir}/bin/mysql -e "INSERT INTO testdb.users (name,age) VALUES('Bob',20);" -uroot --socket=#{mysql_rootdir}/data/mysql.sock)
      sh %(#{mysql_rootdir}/bin/mysql -e "GRANT SELECT ON performance_schema.* TO 'dog'@'localhost';" -uroot --socket=#{mysql_rootdir}/data/mysql.sock)
      # generate some performance metrics....
      sh %(#{mysql_rootdir}/bin/mysql -e "USE testdb; SELECT * FROM users ORDER BY name;" -uroot --socket=#{mysql_rootdir}/data/mysql.sock)
    end

    task script: ['ci:common:script'] do
      this_provides = [
        'mysql'
      ]
      Rake::Task['ci:common:run_tests'].invoke(this_provides)
    end

    task before_cache: ['ci:common:before_cache']

    task cache: ['ci:common:cache']

    task cleanup: ['ci:common:cleanup'] do
      sh %(mysql -e "DROP USER 'dog'@'localhost';" -uroot --socket=#{mysql_rootdir}/data/mysql.sock)
      sh %(mysql -e "DROP DATABASE testdb;" -uroot --socket=#{mysql_rootdir}/data/mysql.sock)
      `pgrep -f "#{mysql_rootdir}/bin/mysqld" `.split("\n").each do |spid|
          p = spid.to_i
          puts "Stopping #{p}"
          Process.kill "TERM", p
      end
      sh %(rm -rf #{mysql_rootdir}/data)
    end

    task :execute do
      exception = nil
      begin
        %w(before_install install before_script
           script before_cache cache).each do |t|
          Rake::Task["#{flavor.scope.path}:#{t}"].invoke
        end
      rescue => e
        exception = e
        puts "Failed task: #{e.class} #{e.message}".red
      end
      if ENV['SKIP_CLEANUP']
        puts 'Skipping cleanup, disposable environments are great'.yellow
      else
        puts 'Cleaning up'
        Rake::Task["#{flavor.scope.path}:cleanup"].invoke
      end
      fail exception if exception
    end
  end
end
